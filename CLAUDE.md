# CLAUDE.md

## Core Principles

**100% dogfood. Everything crashes immediately.**

- Use `!` everywhere, never `if let` or `guard let`
- Use `try!` everywhere, never `do-catch`
- Any error = immediate crash = we see it in the debugger

Always debug mode, always direct install. This is our tool.

## TDD Development

Each task = 3 commits:
1. Write test (test file is located in: /Users/felixlunzenfichter/Documents/realtime-claude/test-system.js)
2. Make test pass (minimal code only, ignore refactoring rules)
3. Refactor & clean up (apply refactoring rules)

### Refactoring Rules
- Apply ONLY after test passes
- Function ordering: If function A uses function B, then B must be defined below A
- Function ordering: If function A is used before function B, then A should be defined before B
- Functions should be small, do one thing, and have descriptive names
- NO COMMENTS in code - zero tolerance for any comments

## Run

```bash
./test-deploy-run.sh
```

After making any code changes, always run this script to see if everything builds and runs successfully.

