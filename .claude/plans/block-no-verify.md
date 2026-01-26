# Plan: Block --no-verify in Claude Hooks

## Why

The `--no-verify` flag bypasses git hooks, which violates TDD discipline.

Git hooks enforce:
- Commit message format (plan: | test: | impl: | refactor:)
- Branch protection (no commits to development/main)
- Test validation before push

If Claude agents can use `--no-verify`, they can bypass all these safeguards.

## What

Add a check in the Claude hook to block any Bash command containing `--no-verify`.

The check should:
1. Extract the command from Bash tool input
2. Check if it contains `--no-verify`
3. If yes, exit 2 with clear error message

## Where

File: `.claude/hooks/limit-main-agent.sh`
Location: Inside the Bash section (RULE 2), after checking run_in_background and dangerouslyDisableSandbox, before the "ALLOWED" exit.

## Expected Behavior

When a Bash command contains `--no-verify`:
- Log: `RESULT: BLOCKED (Bash with --no-verify)`
- Error message: `BLOCKED: --no-verify is forbidden`
- Exit code: 2
