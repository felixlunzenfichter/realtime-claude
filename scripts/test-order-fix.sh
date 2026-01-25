#!/bin/bash
# TEST SPECIFICATION for order check fix

# pre: fresh branch has no commits on it
pre() { [ "$(git rev-list --count HEAD ^origin/development 2>/dev/null)" = "0" ]; }

# post: plan: commit is allowed on fresh branch  
post() { git log -1 --pretty=%s | grep -q "^plan:"; }

# inv: order enforcement only checks branch commits
inv() { grep -q "BRANCH_COMMITS" scripts/hooks/commit-msg.sh; }

# TEST_ORDER_FIX_MARKER
echo "TEST_ORDER_FIX_MARKER: checking order fix"
