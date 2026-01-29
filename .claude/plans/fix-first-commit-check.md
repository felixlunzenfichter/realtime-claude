# Fix First Commit Check

## Problem

Pre-push hook checks if ANY commit has `plan:` prefix, not if the FIRST commit is a plan.

## Fix

Use `--reverse | head -1` to get the first commit on branch.

## File

`scripts/hooks/pre-push.sh`
