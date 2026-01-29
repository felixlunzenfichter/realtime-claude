#!/bin/bash

REPO_ROOT=$(git rev-parse --show-toplevel)
COMMIT_HASH=$(git rev-parse HEAD)
BRANCH_NAME=$(git rev-parse --abbrev-ref HEAD)
COMMIT_MSG=$(git log -1 --format=%s)
AUTOMATED_MARKER="$REPO_ROOT/.test-passed-automated"
MANUAL_MARKER="$REPO_ROOT/.test-passed-manual"
STATUS_FILE="$REPO_ROOT/.test-status"
PLAN_PENDING_FILE="/tmp/plan-pending"

if [[ "$COMMIT_MSG" == plan:* ]]; then
    echo "$COMMIT_MSG" > "$PLAN_PENDING_FILE"
    echo "📋 Plan commit detected. Waiting for iOS approval..."
    exit 0
fi

update_status() {
    echo "$1 $COMMIT_HASH $(date '+%H:%M:%S')" >> "$STATUS_FILE"
    echo "$1"
}

wait_for_marker() {
    local marker_file="$1"
    local expected_hash="$2"

    while true; do
        if [ -f "$marker_file" ]; then
            local marker_content=$(cat "$marker_file")
            if [ "$marker_content" = "ERROR" ]; then
                return 1
            fi
            if [ "$marker_content" = "$expected_hash" ]; then
                return 0
            fi
        fi
        fswatch -1 --event Created --event Updated "$REPO_ROOT" >/dev/null 2>&1
    done
}

echo ""
update_status "📋 STARTED: Running tests [$BRANCH_NAME]"
echo ""

cd "$REPO_ROOT"

rm -f "$AUTOMATED_MARKER" "$MANUAL_MARKER"

update_status "🤖 DEPLOYING_AUTOMATED"
./scripts/deploy-test.sh

if [ $? -ne 0 ]; then
    echo ""
    update_status "❌ FAILED: Automated deploy failed"
    exit 1
fi

echo ""
update_status "⏳ WAITING_AUTOMATED"
if ! wait_for_marker "$AUTOMATED_MARKER" "$COMMIT_HASH"; then
    update_status "❌ FAILED: Automated test error"
    exit 1
fi
update_status "✅ AUTOMATED_PASSED"

echo ""
update_status "👤 DEPLOYING_MANUAL"
./scripts/deploy-test.sh --manual

echo ""
update_status "⏳ WAITING_MANUAL"
if ! wait_for_marker "$MANUAL_MARKER" "$COMMIT_HASH"; then
    update_status "❌ FAILED: Manual test error"
    exit 1
fi
update_status "✅ MANUAL_PASSED"

echo ""
update_status "🚀 PUSHING"
git push origin HEAD

update_status "✅ COMPLETE: All tests passed and pushed"
