# Plan: Block --no-verify

## Goal
Prevent bypassing git hooks with --no-verify flag.

## Implementation
Add to .claude/hooks/ a hook that detects --no-verify usage and blocks it.

## Files Changed
- `.claude/hooks/block-no-verify.sh` (NEW)
