#!/bin/bash

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

if [ "$TOOL_NAME" = "ExitPlanMode" ]; then
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
    if [ -n "$REPO_ROOT" ]; then
        git rev-parse HEAD > "$REPO_ROOT/.plan-accepted"
        echo "✅ Plan accepted."
    fi
fi

exit 0
