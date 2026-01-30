# Claude Code Instructions

## NEVER KILL PRODUCTION

- **iPad = production (port 8082)** - NEVER KILL
- **iPhone = test (port 9999)** - safe to kill

When killing mac-server: `lsof -ti :9999 | xargs kill` NOT `pkill -f mac-server`

## PLAN ACCEPTANCE (AUTO ON EXIT PLAN MODE)

**When you exit plan mode (ExitPlanMode), plan is auto-accepted.**

Hook writes `.plan-accepted` with branch name automatically.

Flow:
1. Enter plan mode → write plan → user approves
2. Exit plan mode → hook auto-accepts
3. Push allowed

## BRANCH PROTECTION

`development` and `main` are protected. PRs required.

## PRE-PUSH RULES

1. Plan must be accepted (via ExitPlanMode)
2. First push must be a `plan:` commit
3. After plan pushed, all pushes allowed

## TEST SYSTEM

| Device | Port | Purpose |
|--------|------|---------|
| iPhone | 9999 | Test builds (safe to break) |
| iPad | 8082 | Production (NEVER break) |

**Workflow:**
1. Test on iPhone (port 9999) - automated then manual
2. Tests pass → PR to development
3. Merge → deploy to iPad (port 8082)

## SKILLS

- `/deploy` - Production deploy to iPad (port 8082)
- `/deploy-test` - Test deploy to iPhone (port 9999)
- `/crash-logs` - Analyze crash logs from iPhone
