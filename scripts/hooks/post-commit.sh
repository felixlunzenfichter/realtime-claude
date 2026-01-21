#!/bin/bash

REPO_ROOT=$(git rev-parse --show-toplevel)
COMMIT_HASH=$(git rev-parse HEAD)
AUTOMATED_MARKER="$REPO_ROOT/.test-passed-automated"
MANUAL_MARKER="$REPO_ROOT/.test-passed-manual"

echo ""
echo "📋 Post-commit: Running tests for $COMMIT_HASH"
echo ""

cd "$REPO_ROOT"

rm -f "$AUTOMATED_MARKER" "$MANUAL_MARKER"

./scripts/deploy-test.sh

if [ $? -ne 0 ]; then
    echo ""
    echo "❌ Automated deploy failed."
    exit 1
fi

echo ""
echo "⏳ Waiting for automated tests to pass..."
while true; do
    if [ -f "$AUTOMATED_MARKER" ]; then
        MARKER_HASH=$(cat "$AUTOMATED_MARKER")
        if [ "$MARKER_HASH" = "$COMMIT_HASH" ]; then
            echo "✅ Automated tests passed"
            break
        fi
    fi
    sleep 1
done

echo ""
echo "📋 Deploying manual test build..."
./scripts/deploy-test.sh --manual

echo ""
echo "⏳ Waiting for manual tests to pass..."
while true; do
    if [ ! -f "$AUTOMATED_MARKER" ]; then
        echo "❌ Error occurred - automated marker deleted"
        exit 1
    fi
    if [ -f "$MANUAL_MARKER" ]; then
        MARKER_HASH=$(cat "$MANUAL_MARKER")
        if [ "$MARKER_HASH" = "$COMMIT_HASH" ]; then
            echo "✅ Manual tests passed"
            break
        fi
    fi
    sleep 1
done

echo ""
echo "🚀 All tests passed. Pushing..."
git push origin HEAD
