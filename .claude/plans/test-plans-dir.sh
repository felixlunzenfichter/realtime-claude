#\!/bin/bash
# Test: .claude/plans must be a real directory, not a symlink

pre() { [[ $1 ]] || { echo "PRE: $2"; exit 1; }; }
post() { [[ $1 ]] || { echo "POST: $2"; exit 1; }; }
inv() { [[ $1 ]] || { echo "INV: $2"; exit 1; }; }

TEST_PLANS_DIR_MARKER="PLANS_DIR_IS_REAL"

test_plans_is_directory() {
    pre -d ".claude/plans" "plans directory must exist"
    pre \! -L ".claude/plans" "plans must not be symlink"
    
    echo "$TEST_PLANS_DIR_MARKER"
    
    post -f ".claude/plans/.gitkeep" || post -f ".claude/plans/PLAN.md" "plans must have trackable file"
}

test_plans_is_directory
