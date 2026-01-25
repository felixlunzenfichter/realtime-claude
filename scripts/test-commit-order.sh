#!/bin/bash
# Automated test for TDD commit order enforcement
# Remove in refactor: step

TEMP_DIR=$(mktemp -d)
HOOK_SOURCE="$1"  # Path to commit-msg.sh

echo "🧪 Testing commit order enforcement"
echo "   Temp dir: $TEMP_DIR"
echo ""

# Setup temp git repo
cd "$TEMP_DIR"
git init -q
git config user.email "test@test.com"
git config user.name "Test"

# Copy hook but disable Claude validation for testing
mkdir -p .git/hooks
sed 's/claude -p --output-format json/false/' "$HOOK_SOURCE" > .git/hooks/commit-msg
chmod +x .git/hooks/commit-msg

PASS_COUNT=0
FAIL_COUNT=0

# Test helper
test_commit() {
    local msg="$1"
    local expect="$2"  # "pass" or "fail"

    echo "x" >> test.txt
    git add test.txt

    OUTPUT=$(git commit -m "$msg" 2>&1)
    EXIT_CODE=$?

    if [ $EXIT_CODE -eq 0 ]; then
        if [ "$expect" = "pass" ]; then
            echo "✅ '$msg' accepted (expected)"
            ((PASS_COUNT++))
        else
            echo "❌ '$msg' accepted (should reject)"
            ((FAIL_COUNT++))
        fi
    else
        if [ "$expect" = "fail" ]; then
            echo "✅ '$msg' rejected (expected)"
            ((PASS_COUNT++))
        else
            echo "❌ '$msg' rejected (should accept)"
            echo "   Output: $OUTPUT"
            ((FAIL_COUNT++))
        fi
    fi
}

echo "=== Test 1: First commit must be plan: ==="
test_commit "test: wrong first" "fail"
test_commit "impl: wrong first" "fail"
test_commit "refactor: wrong first" "fail"
test_commit "plan: correct first" "pass"

echo ""
echo "=== Test 2: After plan: must be test: ==="
test_commit "plan: wrong" "fail"
test_commit "impl: wrong" "fail"
test_commit "refactor: wrong" "fail"
test_commit "test: correct" "pass"

echo ""
echo "=== Test 3: After test: must be impl: ==="
test_commit "plan: wrong" "fail"
test_commit "test: wrong" "fail"
test_commit "refactor: wrong" "fail"
test_commit "impl: correct" "pass"

echo ""
echo "=== Test 4: After impl: must be refactor: ==="
test_commit "plan: wrong" "fail"
test_commit "test: wrong" "fail"
test_commit "impl: wrong" "fail"
test_commit "refactor: correct" "pass"

echo ""
echo "=== Test 5: After refactor: no more commits ==="
test_commit "plan: done" "fail"
test_commit "test: done" "fail"
test_commit "impl: done" "fail"
test_commit "refactor: done" "fail"

echo ""
echo "================================"
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
echo "================================"

# Cleanup
rm -rf "$TEMP_DIR"

if [ $FAIL_COUNT -gt 0 ]; then
    exit 1
fi

echo "🎉 All tests passed!"
