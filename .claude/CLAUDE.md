# Claude Code Instructions

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

## SKILLS

- `/deploy` - Production deploy to iPad
- `/deploy-test` - Test deploy to iPhone
- `/crash-logs` - Analyze crash logs
