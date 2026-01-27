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

{
    echo "════════════════════════════════════════════════════════════════"
    echo "TIME: $(date)"
    echo "TOOL: $TOOL_NAME"
    echo "CWD: $CWD"
    echo "BRANCH: $BRANCH"
    echo "IS_WORKTREE: $IS_WORKTREE"
} >> "$LOG_FILE"

pre() {
    local condition="$1"
    local message="$2"
    if [ "$condition" != "true" ]; then
        echo "RESULT: BLOCKED ($message)" >> "$LOG_FILE"
        echo "════════════════════════════════════════════════════════════════" >> "$LOG_FILE"
        echo "" >&2
        echo "PRE: $message" >&2
        exit 2
    fi
}

if [ "$TOOL_NAME" = "Task" ]; then
    RUN_IN_BG=$(echo "$INPUT" | jq -r '.tool_input.run_in_background // false')
    if [ "$RUN_IN_BG" = "true" ]; then
        echo "RESULT: ALLOWED (Task with run_in_background)" >> "$LOG_FILE"
        echo "════════════════════════════════════════════════════════════════" >> "$LOG_FILE"
        exit 0
    else
        echo "RESULT: BLOCKED (Task without run_in_background)" >> "$LOG_FILE"
        echo "════════════════════════════════════════════════════════════════" >> "$LOG_FILE"
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

    NO_VERIFY_CHECK=$(echo "$COMMAND" | grep -qE '\-\-no-verify' && echo "false" || echo "true")
    pre "$NO_VERIFY_CHECK" "git commands must not contain --no-verify"

    if [ "$RUN_IN_BG" != "true" ]; then
        echo "RESULT: BLOCKED (Bash without run_in_background)" >> "$LOG_FILE"
        echo "════════════════════════════════════════════════════════════════" >> "$LOG_FILE"
        echo "" >&2
        echo "BLOCKED: Bash requires run_in_background: true" >&2
        echo "Run commands in background to avoid blocking." >&2
        exit 2
    elif [ "$DISABLE_SANDBOX" != "true" ]; then
        echo "RESULT: BLOCKED (Bash without dangerouslyDisableSandbox)" >> "$LOG_FILE"
        echo "════════════════════════════════════════════════════════════════" >> "$LOG_FILE"
        echo "" >&2
        echo "BLOCKED: Bash requires dangerouslyDisableSandbox: true" >&2
        echo "Sandbox blocks output file writes. Disable it for background commands." >&2
        exit 2
    else
        echo "RESULT: ALLOWED (Bash with run_in_background + dangerouslyDisableSandbox)" >> "$LOG_FILE"
        echo "════════════════════════════════════════════════════════════════" >> "$LOG_FILE"
        exit 0
    fi
fi

if [ "$TOOL_NAME" = "Edit" ] || [ "$TOOL_NAME" = "Write" ]; then
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
    if [[ "$FILE_PATH" == *"/.claude/plans/"* ]]; then
        echo "RESULT: ALLOWED ($TOOL_NAME to plans directory)" >> "$LOG_FILE"
        echo "════════════════════════════════════════════════════════════════" >> "$LOG_FILE"
        exit 0
    fi

    if [ "$IS_WORKTREE" = "true" ]; then
        echo "RESULT: ALLOWED ($TOOL_NAME in worktree)" >> "$LOG_FILE"
        echo "════════════════════════════════════════════════════════════════" >> "$LOG_FILE"
        exit 0
    else
        echo "RESULT: BLOCKED ($TOOL_NAME not in worktree)" >> "$LOG_FILE"
        echo "════════════════════════════════════════════════════════════════" >> "$LOG_FILE"
        echo "" >&2
        echo "BLOCKED: $TOOL_NAME not allowed outside worktree." >&2
        echo "CWD: $CWD (branch: $BRANCH)" >&2
        echo "Switch to worktree: cd /Users/felixlunzenfichter/Documents/worktrees/<branch>" >&2
        exit 2
    fi
fi

echo "RESULT: ALLOWED ($TOOL_NAME)" >> "$LOG_FILE"
echo "════════════════════════════════════════════════════════════════" >> "$LOG_FILE"
exit 0
