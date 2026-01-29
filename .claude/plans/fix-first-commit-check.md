# Fix First Commit Check

## Problem

The pre-push hook checks if ANY commit has `plan:` prefix, not if the FIRST commit is a plan.

## Current (bug)

```bash
COMMITS=$(git log origin/development..HEAD --oneline)
if echo "$COMMITS" | grep -q "^[a-f0-9]* plan:"; then
```

## Fix

```bash
FIRST_COMMIT=$(git log origin/development..HEAD --oneline --reverse | head -1)
if echo "$FIRST_COMMIT" | grep -q "^[a-f0-9]* plan:"; then
```

`--reverse` shows oldest first, `head -1` gets the first commit.

## File

`scripts/hooks/pre-push.sh`
