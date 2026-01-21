#!/bin/bash

REPO_ROOT=$(git rev-parse --show-toplevel)
COMMIT_HASH=$(git rev-parse HEAD)

echo ""
echo "📋 Post-commit: Running tests for $COMMIT_HASH"
echo ""

cd "$REPO_ROOT"
./scripts/deploy-test.sh

if [ $? -eq 0 ]; then
    echo ""
    echo "📋 Automated tests passed. Deploying manual test build..."
    echo ""
    ./scripts/deploy-test.sh --manual
    echo ""
    echo "📋 Manual test deployed. Verify the app works."
    echo "   Then: ./scripts/mark-manual-passed.sh"
    echo "   Then: git push"
else
    echo ""
    echo "❌ Automated tests failed. Fix and commit again."
fi
