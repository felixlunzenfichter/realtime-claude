#!/bin/bash

# Hook: PreToolUse - blocks heavy tools in main repo
# Main agent = coordinator only. Work happens in worktrees via background agents.
# Exit code 2 = block, message to stderr

if [ -d "$CLAUDE_PROJECT_DIR/.git" ]; then
  echo "BLOCKED: Main agent is coordinator only. Use Task tool to spawn background agent in worktree." >&2
  exit 2
fi

# Worktree - allow
exit 0
