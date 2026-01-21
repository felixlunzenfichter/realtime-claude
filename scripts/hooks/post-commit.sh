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

echo ""
echo "🎤 Manual test deployed. Verify the app works."
echo ""
read -p "Did manual test pass? (y/n): " answer

if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
    echo "$COMMIT_HASH" > "$REPO_ROOT/.test-passed-manual"
    echo "✅ Wrote .test-passed-manual ($COMMIT_HASH)"
    echo ""
    echo "🚀 All tests passed. Pushing..."
    git push origin HEAD
else
    echo "❌ Manual test failed. Fix and commit again."
    rm -f "$REPO_ROOT/.test-passed-automated"
    rm -f "$REPO_ROOT/.test-passed-manual"
fi
