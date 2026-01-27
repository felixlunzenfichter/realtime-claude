#!/bin/bash

REPO_ROOT=$(git rev-parse --show-toplevel)
COMMIT_HASH=$(git rev-parse HEAD)
COMMIT_MSG=$(git log -1 --format=%s)

if [[ "$COMMIT_MSG" == plan:* ]]; then
    if [ ! -f "$REPO_ROOT/.plan-accepted" ]; then
        echo "❌ Plan not accepted. Use ExitPlanMode."
        exit 1
    fi
    if [ "$(cat "$REPO_ROOT/.plan-accepted")" != "$COMMIT_HASH" ]; then
        echo "❌ Wrong commit hash in .plan-accepted"
        exit 1
    fi
    rm -f "$REPO_ROOT/.plan-accepted"
fi

exit 0
