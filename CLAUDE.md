# CLAUDE.md

## System Information
- **Current Date: September 26, 2025**
- **iOS 26** (Release Date: September 15, 2025)
- **iPadOS 26** (Release Date: September 15, 2025)
- **macOS 26 Tahoe** (Release Date: September 15, 2025)
- **Xcode 18** (Release Date: September 2025)
- **OpenAI Realtime API Version**: gpt-realtime (GA since Aug 28, 2025)
- Note: Apple changed numbering to unify all OS versions at "26" for 2025-2026 season

## Core Principles

**100% dogfood. The app must never crash.**

- NEVER use `!` or `try!` - always use safe unwrapping
- Use `guard let` or `if let` for all optionals
- When something is nil or errors occur: use `error()` to log it
- Pattern: `guard let x = y else { error("y was nil"); return }`
- Why: We want fast builds without debug symbols but still get proper error logs
- After the error has been successfully transmitted to Mac, we will automatically restart the app
- Use `error()` heavily in any case that would usually generate a crash

Always debug mode, always direct install. This is our tool.

## TDD Development

Each task = 3 commits:
1. Write test (test file is located in: scripts/test-system.js)
2. Make test pass (minimal code only, ignore refactoring rules)
3. Refactor & clean up (apply refactoring rules)

### Implementation Rules (Step 2)
- Focus on making test pass quickly
- Comment heavily mentioning resources, documentation links, API references
- Include TODO comments for things to clean up in refactoring
- Document any assumptions or gotchas discovered
- Make heavy use of log() and error() functions (see Logger.swift for usage)
- Log all successes and especially catch ALL errors with error()

### Refactoring Rules (Step 3)
- Apply ONLY after test passes
- Function ordering: If function A uses function B, then B must be defined below A
- Function ordering: If function A is used before function B, then A should be defined before B
- Functions should be small, do one thing, and have descriptive names
- NO COMMENTS in code - zero tolerance for any comments, express yourself only in logs
- Clean up any TODO items from implementation phase
- Code should read like well-written prose

## Run

```bash
./scripts/deploy-in-window.sh
```

**ALWAYS use deploy-in-window.sh, NEVER run deploy.sh directly from Claude Code.**

Why: deploy.sh blocks the current process. If interrupted, it kills Claude Code. The deploy-in-window.sh script switches to the scripts Terminal window and executes deployment there, allowing you to interrupt it without killing everything.

After making any code changes, always run deploy-in-window.sh to build, deploy, and run the app.

