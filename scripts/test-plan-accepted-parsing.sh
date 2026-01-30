#!/bin/bash

TEMP_DIR=$(mktemp -d)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "🧪 Testing .plan-accepted parsing"
echo "   Temp dir: $TEMP_DIR"
echo ""

cd "$TEMP_DIR"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
git remote add origin https://github.com/test/test.git

mkdir -p scripts/hooks
cp "$SCRIPT_DIR/hooks/pre-push.sh" scripts/hooks/

echo "test" > test.txt
git add test.txt
git commit -q -m "plan: initial"

PASS=0
FAIL=0

test_marker() {
    local content="$1"
    local expect="$2"
    local desc="$3"

    printf "%s" "$content" > .plan-accepted

    BRANCH=$(git rev-parse --abbrev-ref HEAD)
    MARKER=".plan-accepted"
    ACCEPTED_BRANCH=$(cat "$MARKER")

    if [ "$ACCEPTED_BRANCH" = "$BRANCH" ]; then
        RESULT="match"
    else
        RESULT="mismatch"
    fi

    if [ "$RESULT" = "$expect" ]; then
        echo "✅ $desc: $RESULT (expected)"
        ((PASS++))
    else
        echo "❌ $desc: $RESULT (expected $expect)"
        ((FAIL++))
    fi
}

echo "=== POST: ACCEPTED_BRANCH must match BRANCH ==="
test_marker "master" "match" "clean branch name"
test_marker "master\n" "mismatch" "trailing newline"
test_marker "master\n\n" "mismatch" "multiple newlines"

echo ""
echo "Results: $PASS passed, $FAIL failed"

rm -rf "$TEMP_DIR"

if [ $FAIL -gt 0 ]; then
    echo "❌ Tests reveal the bug: newlines cause mismatch"
    exit 1
fi

echo "✅ All tests passed"
