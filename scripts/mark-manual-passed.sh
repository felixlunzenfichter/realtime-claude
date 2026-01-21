#!/bin/bash

REPO_ROOT=$(git rev-parse --show-toplevel)
COMMIT_HASH=$(git rev-parse HEAD)

echo "$COMMIT_HASH" > "$REPO_ROOT/.test-passed-manual"
echo "✅ Wrote .test-passed-manual ($COMMIT_HASH)"
echo "   Ready to push."
