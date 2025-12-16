#!/bin/bash

# Hook: Stop - fires when Claude finishes responding
# Notifies mac-server that Claude is idle/waiting

STATE_FILE="$CLAUDE_PROJECT_DIR/private/claude-state.txt"

# Ensure private directory exists
mkdir -p "$(dirname "$STATE_FILE")"

# Append stopped state with timestamp (allows multiple events to accumulate)
echo "stopped|$(date +%s)" > "$STATE_FILE"

# Return success with no output (to avoid cluttering transcript)
exit 0
