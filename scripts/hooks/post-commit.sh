#!/bin/bash

REPO_ROOT=$(git rev-parse --show-toplevel)
COMMIT_HASH=$(git rev-parse HEAD)
COMMIT_MSG=$(git log -1 --pretty=%B)
BRANCH_NAME=$(git rev-parse --abbrev-ref HEAD)
LOGS_DIR="$REPO_ROOT/private/logs"
STATUS_FILE="$REPO_ROOT/.test-status"

log() {
    echo "$1 [$BRANCH_NAME] $(date '+%H:%M:%S')" >> "$STATUS_FILE"
    echo "$1"
}

get_latest_log() {
    ls -t "$LOGS_DIR"/*.json 2>/dev/null | head -1
}

has_error() {
    local log_file=$(get_latest_log)
    [ -n "$log_file" ] && grep -q '"type":"error"' "$log_file"
}

has_story_complete() {
    local log_file=$(get_latest_log)
    [ -n "$log_file" ] && grep -q "✅ Story complete" "$log_file"
}

wait_for_error() {
    log "⏳ Waiting for error in log..."
    while ! has_error; do
        fswatch -1 --event Created --event Updated "$LOGS_DIR" >/dev/null 2>&1
    done
    log "✅ Error found (test failed as expected)"
}

wait_for_success() {
    log "⏳ Waiting for story complete..."
    while ! has_story_complete; do
        if has_error; then
            log "❌ Error found - test failed"
            exit 1
        fi
        fswatch -1 --event Created --event Updated "$LOGS_DIR" >/dev/null 2>&1
    done
    log "✅ Story complete"
}

cd "$REPO_ROOT"
echo ""

if [[ "$COMMIT_MSG" == test:* ]]; then
    log "🧪 TEST - expecting failure"
    ./scripts/deploy-test.sh
    wait_for_error

elif [[ "$COMMIT_MSG" == impl:* ]]; then
    log "⚙️ IMPL - expecting success"
    ./scripts/deploy-test.sh
    wait_for_success

elif [[ "$COMMIT_MSG" == refactor:* ]]; then
    log "✨ REFACTOR - manual test"
    ./scripts/deploy-test.sh --manual
    wait_for_success
    log "🚀 Pushing..."
    git push origin HEAD --no-verify

elif [[ "$COMMIT_MSG" == plan:* ]]; then
    log "📝 PLAN - no tests"

else
    log "⚠️ Unknown type - skipping"
fi

log "✅ DONE"
