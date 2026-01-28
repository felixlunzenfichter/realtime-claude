#!/bin/bash

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if echo "$COMMAND" | grep -qE 'git\s+(commit|push|merge|rebase|cherry-pick|am).*--no-verify|git\s+.*--no-verify.*(commit|push|merge|rebase|cherry-pick|am)'; then
    echo "❌ --no-verify is not allowed." >&2
    echo "" >&2
    echo "   Claude must use hooks. Only the user can bypass." >&2
    exit 2
fi

exit 0
