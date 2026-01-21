#!/bin/bash

REPO_ROOT=$(git rev-parse --show-toplevel)
COMMIT_HASH=$(git rev-parse HEAD)
AUTOMATED_MARKER="$REPO_ROOT/.test-passed-automated"
MANUAL_MARKER="$REPO_ROOT/.test-passed-manual"
STATUS_FILE="$REPO_ROOT/.test-status"

update_status() {
    echo "$1 $COMMIT_HASH $(date '+%H:%M:%S')" >> "$STATUS_FILE"
    echo "$1"
}

wait_for_marker() {
    local marker_file="$1"
    local expected_hash="$2"
    local check_automated_exists="$3"

    while true; do
        if [ "$check_automated_exists" = "true" ] && [ ! -f "$AUTOMATED_MARKER" ]; then
            update_status "❌ FAILED: Automated marker deleted (error occurred)"
            exit 1
        fi
        if [ -f "$marker_file" ]; then
            local marker_hash=$(cat "$marker_file")
            if [ "$marker_hash" = "$expected_hash" ]; then
                return 0
            fi
        fi
        fswatch -1 --event Created --event Updated --event Removed "$REPO_ROOT" >/dev/null 2>&1
    done
}

echo ""
update_status "📋 STARTED: Running tests"
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
wait_for_marker "$AUTOMATED_MARKER" "$COMMIT_HASH"
update_status "✅ AUTOMATED_PASSED"

echo ""
update_status "👤 DEPLOYING_MANUAL"
./scripts/deploy-test.sh --manual

echo ""
update_status "⏳ WAITING_MANUAL"
wait_for_marker "$MANUAL_MARKER" "$COMMIT_HASH" "true"
update_status "✅ MANUAL_PASSED"

echo ""
update_status "🚀 PUSHING"
git push origin HEAD

update_status "✅ COMPLETE: All tests passed and pushed"
