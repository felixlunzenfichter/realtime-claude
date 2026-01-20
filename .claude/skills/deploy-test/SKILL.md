---
name: deploy-test
description: Deploy TEST version of RealtimeClaude to iPhone. Use when testing experimental changes without affecting production.
allowed-tools: Bash, Read
---

# Deploy Test Skill

Launches TEST deployment and monitors build status until completion.

## How This Skill Works

This skill:
1. Records the current timestamp
2. Launches ./scripts/deploy-test.sh (runs in separate Terminal window)
3. Monitors /tmp/deploy-test.log directly until completion
4. Returns success only when build completes successfully

## Important: TEST vs PRODUCTION

- **deploy-test**: Deploys experimental/test code, safe to break
- **deploy**: Deploys production code, must never break

Use this skill when working in test branches or experimenting with changes.

## Implementation

### Step 1: Record Start Time and Launch Deploy

```bash
cd /Users/felixlunzenfichter/Documents/realtime-claude && date "+%s" > /tmp/deploy-test-start-epoch.txt && ./scripts/deploy-test.sh
```

Run this with `run_in_background: true`.

### Step 2: Wait for Log to Initialize

Wait 3 seconds for deployment to begin:

```bash
sleep 3
```

### Step 3: Monitor /tmp/deploy-test.log Directly

Read the log file periodically using the Read tool to check for:

**Success Markers:**
- "DEPLOYMENT COMPLETE"
- "Build successful"

**Failure Markers:**
- "FATAL"
- "Build failed"
- Build errors (lines starting with "error:")

### Step 4: Polling Strategy

Poll every 2-3 seconds by reading the log file:
- Use Read tool with offset/limit to read recent lines
- Maximum wait time: 5 minutes
- If no completion after 5 minutes, report timeout

### Step 5: Return Result

Provide clear summary:
- **SUCCESS**: "Test deployment complete. Build successful."
- **FAILURE**: "Test deployment failed: [specific error details]"
- **TIMEOUT**: "Test deployment timed out after 5 minutes."

Include:
- Build status
- Any errors found
- Total time elapsed

## Notes

- deploy-test.sh runs in separate Terminal window (persists if Claude Code ends)
- Skill agent does all monitoring itself (no spawning sub-agents)
- Use Read tool to check log contents directly
- Keep it simple and synchronous
- This is for TEST deployments only - production uses /deploy skill
