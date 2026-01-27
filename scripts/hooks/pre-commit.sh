#!/bin/bash

branch=$(git rev-parse --abbrev-ref HEAD)

if [ "$branch" = "development" ]; then
    commit_msg=$(cat "$1" 2>/dev/null || echo "")
    if [[ "$commit_msg" == plan:* ]]; then
        echo "✅ plan: commit allowed on development"
        exit 0
    fi
    echo "❌ Cannot commit to 'development'"
    echo "   Use a feature branch, then create PR."
    echo "   (Exception: plan: commits are allowed)"
    exit 1
fi

if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
    echo "❌ Cannot commit to '$branch'"
    echo "   Use a feature branch, then create PR."
    exit 1
fi

echo "✅ Branch OK: $branch"
exit 0
