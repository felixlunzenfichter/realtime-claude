#!/bin/bash

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

LOG_FILE="/tmp/hook-coordinator.log"

IS_WORKTREE=false
if [[ "$CWD" == *"/worktrees/"* ]]; then
    IS_WORKTREE=true
fi

BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null || echo "unknown")

log() {
    echo "$1" >> "$LOG_FILE"
}

log "════════════════════════════════════════════════════════════════"
log "TIME: $(date)"
log "TOOL: $TOOL_NAME"
log "CWD: $CWD"
log "BRANCH: $BRANCH"
log "IS_WORKTREE: $IS_WORKTREE"

pre() {
    local condition="$1"
    local message="$2"
    if [ "$condition" != "true" ]; then
        log "RESULT: BLOCKED ($message)"
        log "════════════════════════════════════════════════════════════════"
        echo "" >&2
        echo "PRE: $message" >&2
        exit 2
    fi
    log "CHECK: pre($message) passed"
}

if [ "$TOOL_NAME" = "Task" ]; then
    RUN_IN_BG=$(echo "$INPUT" | jq -r '.tool_input.run_in_background // false')
    if [ "$RUN_IN_BG" = "true" ]; then
        log "RESULT: ALLOWED (Task with run_in_background)"
        log "════════════════════════════════════════════════════════════════"
        exit 0
    else
        log "RESULT: BLOCKED (Task without run_in_background)"
        log "════════════════════════════════════════════════════════════════"
        echo "" >&2
        echo "BLOCKED: Task requires run_in_background: true" >&2
        echo "You are the coordinator. Spawn background agents, don't block." >&2
        exit 2
    fi
fi

if [ "$TOOL_NAME" = "Bash" ]; then
    RUN_IN_BG=$(echo "$INPUT" | jq -r '.tool_input.run_in_background // false')
    DISABLE_SANDBOX=$(echo "$INPUT" | jq -r '.tool_input.dangerouslyDisableSandbox // false')
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

    log "Checking Bash command for --no-verify..."
    NO_VERIFY_CHECK=$(echo "$COMMAND" | grep -qE '\-\-no-verify' && echo "false" || echo "true")
    pre "$NO_VERIFY_CHECK" "git commands must not contain --no-verify"

    if [ "$RUN_IN_BG" != "true" ]; then
        log "RESULT: BLOCKED (Bash without run_in_background)"
        log "════════════════════════════════════════════════════════════════"
        echo "" >&2
        echo "BLOCKED: Bash requires run_in_background: true" >&2
        echo "Run commands in background to avoid blocking." >&2
        exit 2
    elif [ "$DISABLE_SANDBOX" != "true" ]; then
        log "RESULT: BLOCKED (Bash without dangerouslyDisableSandbox)"
        log "════════════════════════════════════════════════════════════════"
        echo "" >&2
        echo "BLOCKED: Bash requires dangerouslyDisableSandbox: true" >&2
        echo "Sandbox blocks output file writes. Disable it for background commands." >&2
        exit 2
    else
        log "RESULT: ALLOWED (Bash with run_in_background + dangerouslyDisableSandbox)"
        log "════════════════════════════════════════════════════════════════"
        exit 0
    fi
fi

if [ "$TOOL_NAME" = "Edit" ] || [ "$TOOL_NAME" = "Write" ]; then
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
    if [[ "$FILE_PATH" == *"/.claude/plans/"* ]]; then
        log "RESULT: ALLOWED ($TOOL_NAME to plans directory)"
        log "════════════════════════════════════════════════════════════════"
        exit 0
    fi

    if [ "$IS_WORKTREE" = "true" ]; then
        log "RESULT: ALLOWED ($TOOL_NAME in worktree)"
        log "════════════════════════════════════════════════════════════════"
        exit 0
    else
        log "RESULT: BLOCKED ($TOOL_NAME not in worktree)"
        log "════════════════════════════════════════════════════════════════"
        echo "" >&2
        echo "BLOCKED: $TOOL_NAME not allowed outside worktree." >&2
        echo "CWD: $CWD (branch: $BRANCH)" >&2
        echo "Switch to worktree: cd /Users/felixlunzenfichter/Documents/worktrees/<branch>" >&2
        exit 2
    fi
fi

log "RESULT: ALLOWED ($TOOL_NAME)"
log "════════════════════════════════════════════════════════════════"
exit 0
