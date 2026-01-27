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
| `RealtimeClaude/Logger.swift` | Add STORY, markers, `createPlan()`, `acceptPlan()` |
| `scripts/mac-server.js` | Add `create_plan` and `accept_plan` handlers |
| `scripts/hooks/pre-commit.sh` | Allow plan: commits on development |

## iOS Commands

| Command | Sends to Mac | Mac Returns |
|---------|--------------|-------------|
| "Create plan" | `{type: "create_plan"}` | `{status: "rejected"}` |
| "Accept plan" | `{type: "accept_plan"}` | `{status: "accepted"}` |

## Verification

1. Make plan: commit → marker has FAIL
2. Say "Accept plan" on iPhone → marker has PASS
3. Push succeeds
