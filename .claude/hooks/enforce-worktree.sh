#!/bin/bash

# Hook: PreToolUse - blocks Edit/Write unless in a worktree
# Main repo has .git as directory, worktree has .git as file
# Exit code 2 = block, message to stderr

# Check if .git is a directory (main repo) or file (worktree)
if [ -d "$CLAUDE_PROJECT_DIR/.git" ]; then
  # Main repo - block edits with exit code 2
  echo "BLOCKED: Cannot edit in main repo. Create worktree first: git worktree add ../worktrees/feature -b feature" >&2
  exit 2
fi

# Worktree - allow
exit 0
