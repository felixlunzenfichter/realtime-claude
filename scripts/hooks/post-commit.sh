#!/bin/bash

REPO_ROOT=$(git rev-parse --show-toplevel)
COMMIT_HASH=$(git rev-parse HEAD)

echo ""
echo "📋 Post-commit: Running tests for $COMMIT_HASH"
echo ""

cd "$REPO_ROOT"
./scripts/deploy-test.sh

if [ $? -ne 0 ]; then
    echo ""
    echo "❌ Automated tests failed. Fix and commit again."
    exit 1
fi

echo ""
echo "📋 Automated tests passed. Deploying manual test build..."
echo ""
./scripts/deploy-test.sh --manual

sleep 5

if [ -f "$REPO_ROOT/.test-passed-automated" ]; then
    MARKER_HASH=$(cat "$REPO_ROOT/.test-passed-automated")
    if [ "$MARKER_HASH" = "$COMMIT_HASH" ]; then
        echo "$COMMIT_HASH" > "$REPO_ROOT/.test-passed-manual"
        echo "✅ Wrote .test-passed-manual ($COMMIT_HASH)"
        echo ""
        echo "🚀 No errors. All tests passed. Pushing..."
        git push origin HEAD
    else
        echo "❌ Marker hash mismatch. Tests failed."
    fi
else
    echo "❌ Automated marker deleted (error occurred). Tests failed."
fi
