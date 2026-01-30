#!/bin/bash

BRANCH=$(git rev-parse --abbrev-ref HEAD)
MARKER=".plan-accepted"

if [ "$BRANCH" = "development" ] || [ "$BRANCH" = "main" ]; then
    echo "❌ Cannot push directly to $BRANCH"
    echo "   Create a feature branch first."
    exit 1
fi

if [ ! -f "$MARKER" ]; then
    echo "❌ No plan accepted for this branch."
    echo ""
    echo "   Claude: Use EnterPlanMode, write plan, then ExitPlanMode."
    echo "   Hook auto-writes .plan-accepted on ExitPlanMode."
    exit 1
fi

ACCEPTED_BRANCH=$(head -1 "$MARKER")
echo "📋 Read branch from marker: '$ACCEPTED_BRANCH'"

if [ "$ACCEPTED_BRANCH" != "$BRANCH" ]; then
    echo "❌ Plan accepted for '$ACCEPTED_BRANCH', not '$BRANCH'"
    echo ""
    echo "   Claude: Use EnterPlanMode on this branch, then ExitPlanMode."
    exit 1
fi

REMOTE_EXISTS=$(git ls-remote --heads origin "$BRANCH" 2>/dev/null)

if [ -z "$REMOTE_EXISTS" ]; then
    FIRST_COMMIT=$(git log origin/development..HEAD --oneline --reverse 2>/dev/null | head -1)
    if [ -z "$FIRST_COMMIT" ]; then
        FIRST_COMMIT=$(git log HEAD --oneline --reverse | head -1)
    fi
    if echo "$FIRST_COMMIT" | grep -q "^[a-f0-9]* plan:"; then
        echo "✅ Pushing plan commit..."
        exit 0
    else
        echo "❌ First push must be a plan: commit."
        echo ""
        echo "   Claude: Create a commit with message starting with 'plan:'"
        echo "   Example: git commit -m 'plan: implement feature X'"
        exit 1
    fi
fi

PLAN_ON_REMOTE=$(git log "origin/$BRANCH" --oneline 2>/dev/null | grep "^[a-f0-9]* plan:" | head -1)

if [ -z "$PLAN_ON_REMOTE" ]; then
    echo "❌ No plan: commit found on remote branch."
    echo ""
    echo "   Claude: Push a plan: commit first, then push implementation."
    echo "   The plan commit must be pushed before other commits."
    exit 1
fi

echo "✅ Plan accepted and pushed. Pushing..."
exit 0
