# Plan: Plan Acceptance Gatekeeper

## STORY

| Step | Command | Result |
|------|---------|--------|
| 0 | (wait) | handshake |
| 1 | "Create plan" | rejected |
| 2 | "Accept plan" | accepted |

## Files

| File | Change |
|------|--------|
| `RealtimeClaude/Logger.swift` | Add STORY, markers, createPlan(), acceptPlan() |
| `scripts/mac-server.js` | Add create_plan and accept_plan handlers |
