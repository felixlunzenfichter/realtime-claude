#!/bin/bash

COMMIT_MSG=$(git log -1 --format=%s)

if [[ "$COMMIT_MSG" == plan:* ]]; then
    echo ""
    echo "📋 Plan committed. Accept in Claude Code CLI to push."
    echo "   (ExitPlanMode writes .plan-accepted)"
    echo ""
    exit 0
fi

echo ""
echo "🚀 Pushing..."
git push origin HEAD

if [ $? -eq 0 ]; then
    echo "✅ Pushed."
else
    echo "❌ Push failed."
    exit 1
fi
