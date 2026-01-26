#!/bin/bash

COMMIT_MSG=$(cat "$1")
GIT_DIFF=$(git diff --cached)

if [[ "$COMMIT_MSG" == plan:* ]]; then
    TYPE="plan"
    PROMPT="PLANNING COMMIT.

PASS if diff adds:
- Design documents or architecture decisions
- Plan files (.md planning docs)
- TODO lists or task breakdowns
- Interface definitions (what, not how)

Defines the approach before implementation.

FAIL if:
- Contains implementation code
- Contains test code (contracts)
- No planning content added

You MUST return exactly this JSON format: {\"pass\": true, \"reason\": \"explanation\"} or {\"pass\": false, \"reason\": \"what is missing\"}"

elif [[ "$COMMIT_MSG" == test:* ]]; then
    TYPE="test"
    PROMPT="SPECIFICATION COMMIT.

PASS if diff adds:
- pre(condition, message) - precondition guards
- post(condition, message) - postcondition guards
- inv(condition, message) - invariant guards
- STORY test case entries
- TEST_*_MARKER definitions
- Test functions that emit markers

Any combination valid. Defines WHAT must be true.

FAIL if:
- None of above added
- ANY log() that isn't a test marker
- Business logic

You MUST return exactly this JSON format: {\"pass\": true, \"reason\": \"explanation\"} or {\"pass\": false, \"reason\": \"what is missing\"}"

elif [[ "$COMMIT_MSG" == impl:* ]]; then
    TYPE="impl"
    PROMPT="IMPLEMENTATION COMMIT.

PASS if diff adds:
- Narrative output: log() in Swift, echo in bash, console.log in JS
- Logic that makes contracts pass

Story must be told via output statements.

FAIL if:
- No narrative output added
- Only contracts (that's test:)

You MUST return exactly this JSON format: {\"pass\": true, \"reason\": \"explanation\"} or {\"pass\": false, \"reason\": \"what is missing\"}"

elif [[ "$COMMIT_MSG" == refactor:* ]]; then
    TYPE="refactor"
    PROMPT="REFACTOR COMMIT.

PASS if:
- ZERO comments in added lines (no //, /*, #)
- Code is clean and readable

FAIL if:
- Any comment syntax in added lines

You MUST return exactly this JSON format: {\"pass\": true, \"reason\": \"explanation\"} or {\"pass\": false, \"reason\": \"what is missing\"}"

else
    echo ""
    echo "❌ TDD FAIL: Invalid commit prefix"
    echo "   Required: plan: | test: | impl: | refactor:"
    echo ""
    echo "   plan:     Add design docs, architecture, plans"
    echo "   test:     Add pre(), post(), inv() contracts (specification)"
    echo "   impl:     Add log() and logic (implementation)"
    echo "   refactor: Clean up, no comments"
    echo ""
    exit 1
fi

BRANCH_COMMITS=$(git rev-list --count HEAD ^origin/development 2>/dev/null || echo "0")

if [ "$BRANCH_COMMITS" = "0" ]; then
    PREV_MSG=""
else
    PREV_MSG=$(git log --oneline HEAD ^origin/development 2>/dev/null | head -1 | cut -d' ' -f2-)
fi

case "$TYPE" in
    plan)
        if [[ -n "$PREV_MSG" ]]; then
            echo ""
            echo "❌ ORDER: plan: must be first commit"
            echo "   Previous: $PREV_MSG"
            echo ""
            exit 1
        fi
        ;;
    test)
        if [[ "$PREV_MSG" != plan:* ]]; then
            echo ""
            echo "❌ ORDER: test: must follow plan:"
            echo "   Previous: $PREV_MSG"
            echo ""
            exit 1
        fi
        ;;
    impl)
        if [[ "$PREV_MSG" != test:* ]]; then
            echo ""
            echo "❌ ORDER: impl: must follow test:"
            echo "   Previous: $PREV_MSG"
            echo ""
            exit 1
        fi
        ;;
    refactor)
        if [[ "$PREV_MSG" != impl:* ]]; then
            echo ""
            echo "❌ ORDER: refactor: must follow impl:"
            echo "   Previous: $PREV_MSG"
            echo ""
            exit 1
        fi
        ;;
esac

STAGED_FILES=$(git diff --cached --name-status)
REPO_ROOT=$(git rev-parse --show-toplevel)

echo ""
echo "📋 TDD Trace Enforcement"
echo "   Type: $TYPE"
echo "   Checking trace file requirements..."

TEST_TRACE_FAILING_pre() {
    echo "   Looking for .test-trace-failing in staged files..."
    if ! echo "$STAGED_FILES" | grep -q "\.test-trace-failing"; then
        echo ""
        echo "❌ TRACE: test: requires .test-trace-failing in diff"
        echo "   pre(trace_failing_in_diff, 'RED phase proof missing')"
        echo ""
        exit 1
    fi
    echo "   ✓ Found .test-trace-failing - RED phase documented"
}

TEST_AUTOMATED_MARKER_pre() {
    echo "   Checking for .test-passed-automated marker..."
    if [ ! -f "$REPO_ROOT/.test-passed-automated" ]; then
        echo ""
        echo "❌ TRACE: impl: requires .test-passed-automated to exist"
        echo "   pre(automated_marker_exists, 'GREEN phase proof missing')"
        echo ""
        exit 1
    fi
    local marker_hash=$(cat "$REPO_ROOT/.test-passed-automated")
    echo "   ✓ Found .test-passed-automated - GREEN phase verified"
    echo "   Marker hash: ${marker_hash:0:8}..."
}

TEST_CLEANUP_pre() {
    echo "   Checking both test markers exist..."
    if [ ! -f "$REPO_ROOT/.test-passed-automated" ] || [ ! -f "$REPO_ROOT/.test-passed-manual" ]; then
        echo ""
        echo "❌ TRACE: refactor: requires both test markers to exist"
        echo "   pre(both_markers_exist, 'Tests must pass before cleanup')"
        echo ""
        exit 1
    fi
    echo "   ✓ Both markers exist - tests passed"

    echo "   Checking trace file deletions in staged diff..."
    local missing_deletions=""

    if ! echo "$STAGED_FILES" | grep -q "^D.*\.test-trace-failing"; then
        if [ -f "$REPO_ROOT/.test-trace-failing" ]; then
            missing_deletions="$missing_deletions .test-trace-failing"
        fi
    fi

    if ! echo "$STAGED_FILES" | grep -q "^D.*\.test-passed-automated"; then
        missing_deletions="$missing_deletions .test-passed-automated"
    fi

    if ! echo "$STAGED_FILES" | grep -q "^D.*\.test-passed-manual"; then
        missing_deletions="$missing_deletions .test-passed-manual"
    fi

    if ! echo "$STAGED_FILES" | grep -q "^D.*.claude/plans/"; then
        if ls "$REPO_ROOT/.claude/plans/"*.md 2>/dev/null | grep -v ".gitkeep" | head -1 > /dev/null; then
            missing_deletions="$missing_deletions plan-file"
        fi
    fi

    if [ -n "$missing_deletions" ]; then
        echo ""
        echo "❌ TRACE: refactor: must delete trace files"
        echo "   pre(all_traces_deleted, 'Missing deletions:$missing_deletions')"
        echo ""
        exit 1
    fi
    echo "   ✓ All trace files being deleted - cleanup complete"
}

case "$TYPE" in
    plan)
        echo "   No trace requirements for plan: commits"
        ;;
    test)
        TEST_TRACE_FAILING_pre
        ;;
    impl)
        TEST_AUTOMATED_MARKER_pre
        ;;
    refactor)
        TEST_CLEANUP_pre
        ;;
esac

echo ""
echo "🔍 TDD Enforcer checking $TYPE commit..."

RESULT=$(claude -p --output-format json "$PROMPT

Diff:
$GIT_DIFF" 2>/dev/null)

if [ $? -ne 0 ]; then
    echo "⚠️  Claude check skipped (not available)"
    exit 0
fi

INNER_JSON=$(echo "$RESULT" | jq -r '.result' 2>/dev/null | sed 's/^```json//; s/^```//; s/```$//' | tr -d '\n')
PASS=$(echo "$INNER_JSON" | jq -r '.pass' 2>/dev/null)
REASON=$(echo "$INNER_JSON" | jq -r '.reason' 2>/dev/null)

if [ "$PASS" != "true" ]; then
    echo "❌ $TYPE FAIL: $REASON"
    exit 1
fi

echo "✅ $TYPE PASS: $REASON"
