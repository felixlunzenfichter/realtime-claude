#!/bin/bash

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

if [ "$TOOL_NAME" = "ExitPlanMode" ]; then
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
    if [ -n "$REPO_ROOT" ]; then
        COMMIT_HASH=$(git rev-parse HEAD 2>/dev/null)
        echo "$COMMIT_HASH" > "$REPO_ROOT/.plan-accepted"
        echo "✅ Plan accepted. You can now push the plan: commit."
    fi
fi

exit 0
