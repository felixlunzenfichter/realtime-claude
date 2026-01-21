#!/bin/bash

branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$branch" = "development" ] || [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
    echo "❌ Cannot commit to '$branch'"
    echo "   Use a feature branch, then create PR."
    exit 1
fi

echo "✅ Branch OK: $branch"
exit 0
