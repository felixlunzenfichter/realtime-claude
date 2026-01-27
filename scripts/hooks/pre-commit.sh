#!/bin/bash

branch=$(git rev-parse --abbrev-ref HEAD)

# Block commits to protected branches
if [ "$branch" = "development" ] || [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
    echo "❌ Cannot commit to '$branch'"
    echo "   Use a feature branch, then create PR."
    exit 1
fi

# Block if unpushed commits exist (enforces order: commit → test → push → next commit)
UNPUSHED=$(git log origin/$branch..HEAD --oneline 2>/dev/null | wc -l | tr -d ' ')
if [ "$UNPUSHED" -gt 0 ]; then
    echo "❌ Previous commit not pushed yet ($UNPUSHED unpushed)"
    echo "   Wait for post-commit hook to finish testing and pushing."
    exit 1
fi

echo "✅ Branch OK: $branch"
exit 0
