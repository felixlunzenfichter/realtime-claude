# Plan: iOS Merge Approval System

## Problem
Claude can prepare PRs but should not merge without user approval.
Need a cryptographic lock that only iOS button can unlock.

## Architecture

```
Claude runs merge → Hook blocks → iOS button tap → Hook unblocks → Merge completes
```

### Components

1. **Pre-push hook** (`scripts/hooks/pre-push.sh`)
   - Blocks and waits for approval file
   - Validates token freshness (< 30 seconds)
   - Times out after 60 seconds

2. **Mac server handler** (`mac-server.js`)
   - Receives `MERGE_PR` command from iOS
   - Writes approval token to `/tmp/.merge-approval`

3. **iOS Merge Button** (`DiffView`)
   - Green checkmark button in ToggleBar
   - Sends `MERGE_PR` command to Mac server

## Flow

1. Claude: `git push && gh pr merge`
2. Pre-push hook: "⏳ Waiting for iOS approval..."
3. User sees diff in DiffView, taps [✓]
4. iOS → Mac: `MERGE_PR`
5. Mac writes `/tmp/.merge-approval`
6. Hook detects file, exits 0
7. Push completes, merge completes

## Files to Modify

- `scripts/hooks/pre-push.sh` - Add approval wait
- `mac-server.js` - Handle MERGE_PR command
- `RealtimeClaude/LogListView.swift` - Add merge button to DiffView

## Security

- Only iOS button can write approval file (via Mac server)
- Claude cannot write to /tmp/.merge-approval directly
- Token expires after 30 seconds
- One-time use (deleted after validation)
