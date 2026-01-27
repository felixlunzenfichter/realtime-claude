#!/bin/bash

COMMIT_MSG=$(cat "$1")
GIT_DIFF=$(git diff --cached)

log() {
    echo "$1"
}

pre() {
    local condition="$1"
    local message="$2"
    if [ "$condition" != "true" ]; then
        log ""
        log "❌ ORDER: $message"
        log ""
        exit 1
    fi
    log "   ✓ PRE: $message"
}

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
    log ""
    log "❌ TDD FAIL: Invalid commit prefix"
    log "   Required: plan: | test: | impl: | refactor:"
    log ""
    exit 1
fi

UPSTREAM=$(git rev-parse --abbrev-ref @{upstream} 2>/dev/null)
if [ -n "$UPSTREAM" ]; then
    BRANCH_COMMITS=$(git rev-list --count HEAD ^"$UPSTREAM" 2>/dev/null || echo "0")
else
    BRANCH_COMMITS=$(git rev-list --count HEAD ^origin/development 2>/dev/null || echo "0")
fi

IS_FIRST_COMMIT="false"
if [ "$BRANCH_COMMITS" = "0" ]; then
    IS_FIRST_COMMIT="true"
    PREV_TYPE=""
else
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

log ""
log "🔍 TDD Order Check..."
log "   Branch commits: $BRANCH_COMMITS"
log "   Previous type: ${PREV_TYPE:-none}"
log "   Current type: $TYPE"

case "$TYPE" in
    plan)
        pre "$IS_FIRST_COMMIT" "plan: must be first commit on branch (previous: $PREV_TYPE)"
        ;;
    test)
        pre "$([[ "$PREV_TYPE" == "plan" ]] && echo true || echo false)" "test: must follow plan: (previous: $PREV_TYPE)"
        ;;
    impl)
        pre "$([[ "$PREV_TYPE" == "test" ]] && echo true || echo false)" "impl: must follow test: (previous: $PREV_TYPE)"
        ;;
    refactor)
        pre "$([[ "$PREV_TYPE" == "impl" ]] && echo true || echo false)" "refactor: must follow impl: (previous: $PREV_TYPE)"
        ;;
esac

log ""
log "🔍 TDD Enforcer checking $TYPE commit..."

RESULT=$(claude -p --output-format json "$PROMPT

Diff:
$GIT_DIFF" 2>/dev/null)

if [ $? -ne 0 ]; then
    log "⚠️  Claude check skipped (not available)"
    exit 0
fi

INNER_JSON=$(echo "$RESULT" | jq -r '.result' 2>/dev/null | sed 's/^```json//; s/^```//; s/```$//' | tr -d '\n')
PASS=$(echo "$INNER_JSON" | jq -r '.pass' 2>/dev/null)
REASON=$(echo "$INNER_JSON" | jq -r '.reason' 2>/dev/null)

if [ "$PASS" != "true" ]; then
    log "❌ $TYPE FAIL: $REASON"
    exit 1
fi

log "✅ $TYPE PASS: $REASON"
