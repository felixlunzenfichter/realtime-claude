#!/bin/bash

REPO_ROOT=$(git rev-parse --show-toplevel)
COMMIT_HASH=$(git rev-parse HEAD)

AUTOMATED_FILE="$REPO_ROOT/.test-passed-automated"

if [ ! -f "$AUTOMATED_FILE" ]; then
    echo "❌ Automated tests not run for this commit."
    echo "   Run: ./scripts/deploy-test.sh"
    exit 1
fi

AUTOMATED_HASH=$(cat "$AUTOMATED_FILE")
if [ "$AUTOMATED_HASH" != "$COMMIT_HASH" ]; then
    echo "❌ Automated tests not passed for HEAD ($COMMIT_HASH)"
    echo "   Marker has: $AUTOMATED_HASH"
    echo "   Run: ./scripts/deploy-test.sh"
    exit 1
fi

MANUAL_FILE="$REPO_ROOT/.test-passed-manual"

if [ ! -f "$MANUAL_FILE" ]; then
    echo "❌ Manual tests not run for this commit."
    echo "   Run: ./scripts/deploy-test.sh --manual"
    exit 1
fi

MANUAL_HASH=$(cat "$MANUAL_FILE")
if [ "$MANUAL_HASH" != "$COMMIT_HASH" ]; then
    echo "❌ Manual tests not passed for HEAD ($COMMIT_HASH)"
    echo "   Marker has: $MANUAL_HASH"
    echo "   Run: ./scripts/deploy-test.sh --manual"
    exit 1
fi

echo "✅ All tests passed for $COMMIT_HASH"
echo "   Pushing..."

exit 0
