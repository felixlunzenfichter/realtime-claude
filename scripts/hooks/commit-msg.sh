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

# =============================================================================
# STRICT ORDER ENFORCEMENT
# plan: → test: → impl: → refactor:
# =============================================================================

# Count commits on THIS branch only (since branching from upstream)
UPSTREAM=$(git rev-parse --abbrev-ref @{upstream} 2>/dev/null)
if [ -n "$UPSTREAM" ]; then
    BRANCH_COMMITS=$(git rev-list --count HEAD ^"$UPSTREAM" 2>/dev/null || echo "0")
else
    # No upstream, count from development
    BRANCH_COMMITS=$(git rev-list --count HEAD ^origin/development 2>/dev/null || echo "0")
fi

if [ "$BRANCH_COMMITS" = "0" ]; then
    # First commit on this branch
    PREV_TYPE=""
else
    # Get the previous commit on THIS branch
    PREV_MSG=$(git log -1 --pretty=%B HEAD 2>/dev/null | head -1)
    if [[ "$PREV_MSG" == plan:* ]]; then
        PREV_TYPE="plan"
    elif [[ "$PREV_MSG" == test:* ]]; then
        PREV_TYPE="test"
    elif [[ "$PREV_MSG" == impl:* ]]; then
        PREV_TYPE="impl"
    elif [[ "$PREV_MSG" == refactor:* ]]; then
        PREV_TYPE="refactor"
    else
        PREV_TYPE="unknown"
    fi
fi

case "$TYPE" in
    plan)
        # plan: OK only if first commit on this branch
        if [[ -n "$PREV_TYPE" ]]; then
            echo ""
            echo "❌ ORDER: plan: must be first commit on branch"
            echo "   This branch already has commits (previous: $PREV_TYPE)"
            echo ""
            exit 1
        fi
        ;;
    test)
        if [[ "$PREV_TYPE" != "plan" ]]; then
            echo ""
            echo "❌ ORDER: test: must follow plan:"
            echo "   Previous: $PREV_TYPE"
            echo ""
            exit 1
        fi
        ;;
    impl)
        if [[ "$PREV_TYPE" != "test" ]]; then
            echo ""
            echo "❌ ORDER: impl: must follow test:"
            echo "   Previous: $PREV_TYPE"
            echo ""
            exit 1
        fi
        ;;
    refactor)
        if [[ "$PREV_TYPE" != "impl" ]]; then
            echo ""
            echo "❌ ORDER: refactor: must follow impl:"
            echo "   Previous: $PREV_TYPE"
            echo ""
            exit 1
        fi
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
