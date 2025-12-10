---
name: deploy
description: Check RealtimeClaude build status and errors. Use when asked to build, compile, check for errors, or verify the app compiles.
allowed-tools: Bash, Read
---

# Deploy Skill

Launches deployment and monitors build status until completion.

## How This Skill Works

This skill:
1. Records the current timestamp
2. Launches ./scripts/deploy-in-window.sh (runs in separate Terminal window)
3. Monitors /tmp/deploy.log directly until completion
4. Verifies ALL tests pass (test definitions in RealtimeClaude/Logger.swift TEST_DEFINITIONS)
5. Returns success only when all tests show "✅ Test N passed"

## Implementation

### Step 1: Record Start Time and Launch Deploy

```bash
cd /Users/felixlunzenfichter/Documents/realtime-claude && date "+%s" > /tmp/deploy-start-epoch.txt && ./scripts/deploy-in-window.sh
```

Run this with `run_in_background: true`.

### Step 2: Wait for Log to Initialize

Wait 3 seconds for deployment to begin:

```bash
sleep 3
```

### Step 3: Monitor /tmp/deploy.log Directly

Read the log file periodically using the Read tool to check for:

**Success Markers:**
- "DEPLOYMENT COMPLETE"
- All tests showing "✅ Test N passed"
- "✅ Build successful"

**Failure Markers:**
- "💥 FATAL"
- "❌ Build failed"
- Build errors (lines starting with "error:" or "❌")

**Test Verification:**
- Check RealtimeClaude/Logger.swift for TEST_DEFINITIONS dictionary to know how many tests exist
- Verify each test shows "✅ Test N passed" in the log
- Return success ONLY when ALL tests pass

### Step 4: Polling Strategy

Poll every 2-3 seconds by reading the log file:
- Use Read tool with offset/limit to read recent lines
- Maximum wait time: 5 minutes
- If no completion after 5 minutes, report timeout

### Step 5: Return Result

Provide clear summary:
- **SUCCESS**: "Deployment complete. Build successful, all N tests passed."
- **FAILURE**: "Deployment failed: [specific error details]"
- **TIMEOUT**: "Deployment timed out after 5 minutes."

Include:
- Build status
- Number of tests passed/failed
- Any errors found
- Total time elapsed

## Notes

- deploy-in-window.sh runs in separate Terminal window (persists if Claude Code ends)
- Skill agent does all monitoring itself (no spawning sub-agents)
- Use Read tool to check log contents directly
- Keep it simple and synchronous
