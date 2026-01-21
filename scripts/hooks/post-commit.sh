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
while true; do
    if [ -f "$AUTOMATED_MARKER" ]; then
        MARKER_HASH=$(cat "$AUTOMATED_MARKER")
        if [ "$MARKER_HASH" = "$COMMIT_HASH" ]; then
            update_status "✅ AUTOMATED_PASSED"
            break
        fi
    fi
    sleep 1
done

echo ""
update_status "👤 DEPLOYING_MANUAL"
./scripts/deploy-test.sh --manual

echo ""
update_status "⏳ WAITING_MANUAL"
while true; do
    if [ ! -f "$AUTOMATED_MARKER" ]; then
        update_status "❌ FAILED: Automated marker deleted (error occurred)"
        exit 1
    fi
    if [ -f "$MANUAL_MARKER" ]; then
        MARKER_HASH=$(cat "$MANUAL_MARKER")
        if [ "$MARKER_HASH" = "$COMMIT_HASH" ]; then
            update_status "✅ MANUAL_PASSED"
            break
        fi
    fi
    sleep 1
done

echo ""
update_status "🚀 PUSHING"
git push origin HEAD

update_status "✅ COMPLETE: All tests passed and pushed"
