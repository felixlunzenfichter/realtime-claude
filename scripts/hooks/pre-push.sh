#!/bin/bash

REPO_ROOT=$(git rev-parse --show-toplevel)
COMMIT_HASH=$(git rev-parse HEAD)
COMMIT_MSG=$(git log -1 --format=%s)

if [[ "$COMMIT_MSG" == plan:* ]]; then
    if [ ! -f "$REPO_ROOT/.plan-accepted" ]; then
        echo ""
        echo "❌ Plan not accepted. Use ExitPlanMode in Claude Code."
        echo ""
        exit 1
    fi
    if [ "$(cat "$REPO_ROOT/.plan-accepted")" != "$COMMIT_HASH" ]; then
        echo ""
        echo "❌ Plan accepted for different commit."
        echo "   Expected: $COMMIT_HASH"
        echo "   Found:    $(cat "$REPO_ROOT/.plan-accepted")"
        echo ""
        exit 1
    fi
    echo "✅ Plan accepted."
    rm -f "$REPO_ROOT/.plan-accepted"
    exit 0
fi

# test/impl/refactor - allow push
exit 0
