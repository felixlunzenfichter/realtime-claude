#!/bin/bash

pre() { [[ $1 ]] || { echo "PRE FAILED: $2"; exit 1; }; }
post() { [[ $1 ]] || { echo "POST FAILED: $2"; exit 1; }; }
inv() { [[ $1 ]] || { echo "INV FAILED: $2"; exit 1; }; }

TEST_APPROVAL_MARKER="MERGE_APPROVAL_VALIDATED"
APPROVAL_FILE="/tmp/.merge-approval"

test_approval_required() {
    pre ! -f "$APPROVAL_FILE" "approval file should not exist before test"

    inv ! -f "$APPROVAL_FILE" "no approval = blocked"

    echo "$TEST_APPROVAL_MARKER: approval required"
}

test_approval_freshness() {
    pre -f "$APPROVAL_FILE" "approval file must exist"

    TOKEN_AGE=$(( $(date +%s) - $(stat -f %m "$APPROVAL_FILE" 2>/dev/null || echo 0) ))
    inv $TOKEN_AGE -lt 30 "token must be < 30 seconds old"

    echo "$TEST_APPROVAL_MARKER: freshness validated"
}

test_approval_one_time() {
    pre -f "$APPROVAL_FILE" "approval file must exist before use"

    rm -f "$APPROVAL_FILE"

    post ! -f "$APPROVAL_FILE" "approval file must be deleted after use"

    echo "$TEST_APPROVAL_MARKER: one-time use validated"
}

echo "Merge approval contracts defined"
