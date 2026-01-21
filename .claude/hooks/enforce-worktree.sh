#!/bin/bash

# Hook: PreToolUse - enforces coordinator pattern in main repo
# Main agent can only: Read, Glob, Grep, Task (background only)
# Exit code 2 = block, message to stderr

# Only enforce in main repo (not worktrees)
if [ ! -d "$CLAUDE_PROJECT_DIR/.git" ]; then
  exit 0
fi

# Read tool input from stdin
INPUT=$(cat)

# Sub-agents (transcript filename starts with "agent-") are allowed everything
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
TRANSCRIPT_FILENAME=$(basename "$TRANSCRIPT_PATH" 2>/dev/null)
if [[ "$TRANSCRIPT_FILENAME" == agent-* ]]; then
  exit 0
fi

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Task tool: only allow if run_in_background is true
if [ "$TOOL_NAME" = "Task" ]; then
  RUN_IN_BG=$(echo "$INPUT" | jq -r '.tool_input.run_in_background // false')
  if [ "$RUN_IN_BG" != "true" ]; then
    echo "BLOCKED: Task must use run_in_background: true. Main agent is coordinator only." >&2
    exit 2
  fi
  exit 0
fi

# All other matched tools (Edit, Write, Bash, WebFetch, WebSearch) are blocked
echo "BLOCKED: Main agent is coordinator only. Use Task tool with run_in_background: true." >&2
exit 2
