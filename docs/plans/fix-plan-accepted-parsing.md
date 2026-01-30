# Plan: Fix .plan-accepted parsing

## Problem

`pre-push.sh` uses `cat` to read `.plan-accepted`, but the file may have trailing newline or extra content, causing branch name comparison to fail.

## Solution

Use `head -1` to read only the first line.

## Changes

1. `scripts/hooks/pre-push.sh` - `cat "$MARKER"` → `head -1 "$MARKER"`
2. `.claude/settings.json` - Add Bash to allowed permissions
