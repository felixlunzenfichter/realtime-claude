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
# =============================================================================
PREV_MSG=$(git log -1 --pretty=%s 2>/dev/null || echo "")

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

echo ""
echo "🔍 TDD Enforcer checking $TYPE commit..."

RESULT=$(claude -p --output-format json "$PROMPT

Diff:
$GIT_DIFF" 2>/dev/null)

if [ $? -ne 0 ]; then
    echo "⚠️  Claude check skipped (not available)"
    exit 0
fi

# Extract the result field, strip markdown code blocks, then parse JSON
INNER_JSON=$(echo "$RESULT" | jq -r '.result' 2>/dev/null | sed 's/^```json//; s/^```//; s/```$//' | tr -d '\n')
PASS=$(echo "$INNER_JSON" | jq -r '.pass' 2>/dev/null)
REASON=$(echo "$INNER_JSON" | jq -r '.reason' 2>/dev/null)

if [ "$PASS" != "true" ]; then
    echo "❌ $TYPE FAIL: $REASON"
    exit 1
fi

echo "✅ $TYPE PASS: $REASON"
