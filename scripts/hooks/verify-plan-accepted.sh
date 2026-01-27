#!/bin/bash

TRANSCRIPT_DIR="$HOME/.claude/projects/-Users-felixlunzenfichter-Documents-realtime-claude"

echo "Checking for plan acceptance in Claude transcripts..."

if [[ ! -d "$TRANSCRIPT_DIR" ]]; then
    echo "FAIL: No transcript directory found"
    exit 1
fi

if command -v rg &>/dev/null; then
    RESULT=$(rg -l --max-count=1 --glob '*.jsonl' 'Implement the following plan' "$TRANSCRIPT_DIR" 2>/dev/null | head -1)
else
    RESULT=$(find "$TRANSCRIPT_DIR" -maxdepth 1 -name '*.jsonl' -exec grep -l 'Implement the following plan' {} + 2>/dev/null | head -1)
fi

if [[ -n "$RESULT" ]]; then
    echo "Found plan acceptance in: $RESULT"
    echo "PASS: Plan acceptance verified"
    exit 0
fi

echo "FAIL: No plan acceptance found - use ExitPlanMode to accept your plan"
exit 1
