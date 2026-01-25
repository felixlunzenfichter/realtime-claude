# Global Claude Code Instructions

## BRANCH PROTECTION

**`development` is protected. No direct commits.**

```
Workflow: worktree → test → push → PR → merge → deploy
Skills:   /deploy-test (iPhone)  /deploy (iPad)  /crash-logs
```

Local pre-commit hook blocks commits to development/main.
GitHub blocks direct push. PRs required.

## MAIN AGENT = COORDINATOR ONLY

**Zero tolerance. Main context is sacred.**

### Main Agent Does:
- Talk to user
- Spawn agents
- Collect summaries
- Make decisions

### Main Agent NEVER Does:
- Bash commands (use run_in_background: true)
- Read files over 100 lines (spawn Explore agent)
- Search codebases (spawn Explore agent)
- Web searches (spawn Task agent)
- Multi-file edits (spawn general-purpose agent)
- Anything that produces output

### Every Single Bash → Background
```
run_in_background: true
```
No exceptions. Even `ls`. Even `git status`. Everything.

### Every Exploration → Agent
```
Task tool → subagent_type: "Explore"
```
Agent reads, searches, returns 1-paragraph summary.

### Why This Extreme?
- 1 deploy with logs = 50k tokens = conversation over
- 1 file read = 2k tokens = wasted forever
- Background agent uses ITS context, returns 100 tokens
- Main stays at 5k tokens, lasts entire session
- User always has responsive agent ready to talk

### The Math
Without this: 200k context ÷ 50k per task = 4 tasks then dead
With this: 200k context ÷ 500 per task = 400 tasks, immortal coordinator

### Pattern
User speaks → Spawn agent → Keep talking → Get summary → Repeat forever

## TDD COMMIT ENFORCEMENT

**Every commit must have prefix: plan: | test: | impl: | refactor:**

commit-msg hook validates via headless Claude agent.

### Universal Rules (Uncle Bob)

1. **BRANCH = TOPIC** - changes must relate to branch name
2. **ONE THING** - focused on single behavior
3. **MESSAGE MATCH** - describes exactly what diff does

### plan: - Design

PASS if diff adds:
- Design documents or architecture decisions
- Plan files (.md planning docs)
- TODO lists or task breakdowns
- Interface definitions (what, not how)

FAIL if:
- Contains implementation code
- Contains test code (contracts)
- No planning content added

### test: - Specification

PASS if diff adds:
- pre(condition, message) - precondition guards
- post(condition, message) - postcondition guards
- inv(condition, message) - invariant guards
- STORY test case entries
- TEST_*_MARKER definitions
- Test functions that emit markers

FAIL if:
- None of above added
- ANY log() that isn't a test marker
- Business logic

### impl: - Implementation

PASS if diff adds:
- log() calls (the story/narrative)
- Logic that makes contracts pass

FAIL if:
- No log() calls added
- Only contracts (that's test:)

### refactor: - Cleanup

PASS if:
- ZERO comments in added lines
- Code is clean and readable

FAIL if:
- Any comment syntax in added lines
