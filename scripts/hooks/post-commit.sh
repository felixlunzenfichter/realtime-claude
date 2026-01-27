#!/bin/bash

REPO_ROOT=$(git rev-parse --show-toplevel)
COMMIT_HASH=$(git rev-parse HEAD)
BRANCH_NAME=$(git rev-parse --abbrev-ref HEAD)
COMMIT_MSG=$(git log -1 --format=%s)
STATUS_FILE="$REPO_ROOT/.test-status"
LOG_FILE="/tmp/mac-server-output.log"
TIMEOUT_SECONDS=120

update_status() {
    echo "$1 $COMMIT_HASH $(date '+%H:%M:%S')" >> "$STATUS_FILE"
    echo "$1"
}

watch_log_for_result() {
    local start_time=$(date +%s)
    local start_line=1

    if [ -f "$LOG_FILE" ]; then
        start_line=$(($(wc -l < "$LOG_FILE") + 1))
    fi

    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))

        if [ $elapsed -ge $TIMEOUT_SECONDS ]; then
            echo "TIMEOUT"
            return
        fi

        if [ -f "$LOG_FILE" ]; then
            local new_content=$(tail -n +$start_line "$LOG_FILE" 2>/dev/null)

            if echo "$new_content" | grep -q "Story complete"; then
                echo "STORY_COMPLETE"
                return
            fi

            if echo "$new_content" | grep -q "error("; then
                echo "ERROR"
                return
            fi
        fi

        sleep 0.5
    done
}

cd "$REPO_ROOT"

if [[ "$COMMIT_MSG" == plan:* ]]; then
    echo ""
    update_status "📋 PLAN COMMIT: No tests needed"
    echo "   Pushing plan commit..."
    echo ""
    git push origin HEAD
    update_status "✅ COMPLETE: plan: commit pushed"
    exit 0

elif [[ "$COMMIT_MSG" == test:* ]]; then
    echo ""
    update_status "📋 TEST COMMIT: Running automated tests (expect FAIL)"
    echo ""

    update_status "🤖 DEPLOYING_AUTOMATED"
    ./scripts/deploy-test.sh

    if [ $? -ne 0 ]; then
        echo ""
        update_status "❌ FAILED: Automated deploy failed"
        exit 1
    fi

    echo ""
    update_status "⏳ WATCHING LOG (expecting error)"
    RESULT=$(watch_log_for_result)

    if [ "$RESULT" = "ERROR" ]; then
        update_status "✅ TEST COMMIT PASSED: Test correctly fails (TDD red phase)"
        echo ""
        update_status "🚀 PUSHING"
        git push origin HEAD
        update_status "✅ COMPLETE: test: commit pushed"
    elif [ "$RESULT" = "STORY_COMPLETE" ]; then
        update_status "❌ TEST COMMIT FAILED: Story completed but should have failed"
        echo "   Your test: commit should add failing tests."
        echo "   If tests pass, there's nothing new to implement."
        exit 1
    else
        update_status "❌ TEST COMMIT FAILED: Timeout waiting for test result"
        exit 1
    fi

elif [[ "$COMMIT_MSG" == impl:* ]]; then
    echo ""
    update_status "📋 IMPL COMMIT: Running automated tests (expect PASS)"
    echo ""

    update_status "🤖 DEPLOYING_AUTOMATED"
    ./scripts/deploy-test.sh

    if [ $? -ne 0 ]; then
        echo ""
        update_status "❌ FAILED: Automated deploy failed"
        exit 1
    fi

    echo ""
    update_status "⏳ WATCHING LOG (expecting Story complete)"
    RESULT=$(watch_log_for_result)

    if [ "$RESULT" = "STORY_COMPLETE" ]; then
        update_status "✅ IMPL COMMIT PASSED: Tests pass (TDD green phase)"
        echo ""
        update_status "🚀 PUSHING"
        git push origin HEAD
        update_status "✅ COMPLETE: impl: commit pushed"
    elif [ "$RESULT" = "ERROR" ]; then
        update_status "❌ IMPL COMMIT FAILED: Tests still failing"
        echo "   Your impl: commit should make tests pass."
        exit 1
    else
        update_status "❌ IMPL COMMIT FAILED: Timeout waiting for test result"
        exit 1
    fi

elif [[ "$COMMIT_MSG" == refactor:* ]]; then
    echo ""
    update_status "📋 REFACTOR COMMIT: Running all tests (expect PASS)"
    echo ""

    update_status "🤖 DEPLOYING_AUTOMATED"
    ./scripts/deploy-test.sh

    if [ $? -ne 0 ]; then
        echo ""
        update_status "❌ FAILED: Automated deploy failed"
        exit 1
    fi

    echo ""
    update_status "⏳ WATCHING LOG (automated - expecting Story complete)"
    RESULT=$(watch_log_for_result)

    if [ "$RESULT" = "ERROR" ]; then
        update_status "❌ REFACTOR FAILED: Automated tests failed"
        echo "   Refactoring should not break tests."
        exit 1
    elif [ "$RESULT" = "TIMEOUT" ]; then
        update_status "❌ REFACTOR FAILED: Timeout waiting for automated test result"
        exit 1
    fi
    update_status "✅ AUTOMATED_PASSED"

    echo ""
    update_status "👤 DEPLOYING_MANUAL"
    ./scripts/deploy-test.sh --manual

    echo ""
    update_status "⏳ WATCHING LOG (manual - expecting Story complete)"
    RESULT=$(watch_log_for_result)

    if [ "$RESULT" = "ERROR" ]; then
        update_status "❌ REFACTOR FAILED: Manual tests failed"
        echo "   Refactoring should not break tests."
        exit 1
    elif [ "$RESULT" = "TIMEOUT" ]; then
        update_status "❌ REFACTOR FAILED: Timeout waiting for manual test result"
        exit 1
    fi
    update_status "✅ MANUAL_PASSED"

    echo ""
    update_status "🚀 PUSHING"
    git push origin HEAD
    update_status "✅ COMPLETE: refactor: commit pushed"

else
    echo ""
    echo "⚠️  Unknown commit type. No tests run."
    echo ""
fi
