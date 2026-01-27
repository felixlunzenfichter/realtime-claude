#!/bin/bash

TEST_PLAN_BLOCKED_MARKER="✓ TEST[1] PASSED: plan_blocked_without_acceptance"
TEST_ACCEPTANCE_WORKS_MARKER="✓ TEST[2] PASSED: acceptance_enables_push"
TEST_AUTO_PUSH_MARKER="✓ TEST[3] PASSED: non_plan_auto_pushes"
TEST_ORDER_MARKER="✓ TEST[4] PASSED: order_enforced"

pre() {
    local condition=$1
    local message=$2
    if [ "$condition" != "true" ]; then
        echo "PRE: $message"
        exit 1
    fi
}

post() {
    local condition=$1
    local message=$2
    if [ "$condition" != "true" ]; then
        echo "POST: $message"
        exit 1
    fi
}

inv() {
    local condition=$1
    local message=$2
    if [ "$condition" != "true" ]; then
        echo "INV: $message"
        exit 1
    fi
}
