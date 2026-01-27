#!/bin/bash

COMMIT_MSG=$(git log -1 --format=%s)

if [[ "$COMMIT_MSG" == plan:* ]]; then
    echo "✅ plan: commit - no additional validation"
    exit 0

elif [[ "$COMMIT_MSG" == test:* ]]; then
    echo "✅ test: commit - validated by post-commit"
    exit 0

elif [[ "$COMMIT_MSG" == impl:* ]]; then
    echo "✅ impl: commit - validated by post-commit"
    exit 0

elif [[ "$COMMIT_MSG" == refactor:* ]]; then
    echo "✅ refactor: commit - validated by post-commit"
    exit 0

else
    echo "⚠️  Unknown commit type: $COMMIT_MSG"
    echo "   Commit types: plan: | test: | impl: | refactor:"
    exit 1
fi
