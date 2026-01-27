#!/bin/bash

pre_transcript_dir_exists() {
    [[ -d "$1" ]] || { echo "PRE: transcript directory must exist: $1"; exit 1; }
}

post_result_is_pass_or_fail() {
    [[ "$1" == "PASS" || "$1" == "FAIL" ]] || { echo "POST: result must be PASS or FAIL, got: $1"; exit 1; }
}

inv_exit_code_matches_result() {
    local result="$1"
    local exit_code="$2"
    if [[ "$result" == "PASS" && "$exit_code" != "0" ]]; then
        echo "INV: PASS must exit 0, got $exit_code"; exit 1
    fi
    if [[ "$result" == "FAIL" && "$exit_code" != "1" ]]; then
        echo "INV: FAIL must exit 1, got $exit_code"; exit 1
    fi
}

TRANSCRIPT_DIR="$HOME/.claude/projects/-Users-felixlunzenfichter-Documents-realtime-claude"

echo "TEST_PLAN_ACCEPTANCE_CHECK_START"
echo ""
echo "=== Plan Acceptance Verification ==="
echo ""
echo "Verifying plan acceptance..."
echo "Checking transcript directory: $TRANSCRIPT_DIR"

pre_transcript_dir_exists "$TRANSCRIPT_DIR"

echo "Transcript directory exists."
echo ""
echo "Searching for 'Implement the following plan' in transcripts..."

if command -v rg &>/dev/null; then
    echo "Using ripgrep for search..."
    MATCH=$(rg -l --max-count=1 --glob '*.jsonl' 'Implement the following plan' "$TRANSCRIPT_DIR" 2>/dev/null | head -1)
else
    echo "Using find/grep for search (ripgrep not available)..."
    MATCH=$(find "$TRANSCRIPT_DIR" -maxdepth 1 -name '*.jsonl' -exec grep -l 'Implement the following plan' {} + 2>/dev/null | head -1)
fi

echo ""
if [[ -n "$MATCH" ]]; then
    echo "Found acceptance evidence in: $MATCH"
    echo "Plan was accepted via ExitPlanMode."
    RESULT="PASS"
    EXIT_CODE=0
else
    echo "No acceptance evidence found in transcripts."
    echo "To accept a plan, use ExitPlanMode with 'Implement the following plan'."
    RESULT="FAIL"
    EXIT_CODE=1
fi

post_result_is_pass_or_fail "$RESULT"
inv_exit_code_matches_result "$RESULT" "$EXIT_CODE"

echo ""
echo "=== Verification Complete ==="
echo "TEST_PLAN_ACCEPTANCE_RESULT: $RESULT"
exit $EXIT_CODE
