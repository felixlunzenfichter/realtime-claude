#!/bin/bash

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

LOG_FILE="/tmp/hook-coordinator.log"

# Check if in worktree
IS_WORKTREE=false
if [[ "$CWD" == *"/worktrees/"* ]]; then
    IS_WORKTREE=true
fi

BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null || echo "unknown")

# Log
{
    echo "════════════════════════════════════════════════════════════════"
    echo "TIME: $(date)"
    echo "TOOL: $TOOL_NAME"
    echo "CWD: $CWD"
    echo "BRANCH: $BRANCH"
    echo "IS_WORKTREE: $IS_WORKTREE"
} >> "$LOG_FILE"

# =============================================================================
# RULE 1: Task must have run_in_background: true
# =============================================================================
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

# =============================================================================
# RULE 2: Bash must have run_in_background: true
# =============================================================================
if [ "$TOOL_NAME" = "Bash" ]; then
    RUN_IN_BG=$(echo "$INPUT" | jq -r '.tool_input.run_in_background // false')
    if [ "$RUN_IN_BG" = "true" ]; then
        echo "RESULT: ALLOWED (Bash with run_in_background)" >> "$LOG_FILE"
        echo "════════════════════════════════════════════════════════════════" >> "$LOG_FILE"
        exit 0
    else
        echo "RESULT: BLOCKED (Bash without run_in_background)" >> "$LOG_FILE"
        echo "════════════════════════════════════════════════════════════════" >> "$LOG_FILE"
        echo "" >&2
        echo "BLOCKED: Bash requires run_in_background: true" >&2
        echo "Run commands in background to avoid blocking." >&2
        exit 2
    fi
fi

# =============================================================================
# RULE 3: Edit/Write must be in worktree
# =============================================================================
if [ "$TOOL_NAME" = "Edit" ] || [ "$TOOL_NAME" = "Write" ]; then
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

# =============================================================================
# RULE 4: Everything else allowed
# =============================================================================
echo "RESULT: ALLOWED ($TOOL_NAME)" >> "$LOG_FILE"
echo "════════════════════════════════════════════════════════════════" >> "$LOG_FILE"
exit 0
