# Claude Code Instructions

## PLAN ACCEPTANCE (REQUIRED BEFORE PUSH)

**Cannot push without accepted plan.**

When user says "accept plan":
1. Write current branch name to `.plan-accepted` file
2. Confirm: "Plan accepted for <branch>. You can now push."

```bash
echo "$(git branch --show-current)" > .plan-accepted
```

Pre-push hook checks this marker. No marker = no push.

## BRANCH PROTECTION

`development` and `main` are protected. PRs required.

Workflow: feature branch → accept plan → push → PR → merge

## SKILLS

- `/deploy` - Production deploy to iPad
- `/deploy-test` - Test deploy to iPhone
- `/crash-logs` - Analyze crash logs
