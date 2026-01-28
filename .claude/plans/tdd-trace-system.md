# Plan: TDD Trace System

## Goal
Prove test execution through committed log traces. No marker files.

## Log Format (with contracts)

```
time | mode | device | type | component | file | function | message
```

| Field | Values | Determined By |
|-------|--------|---------------|
| mode | PROD / TEST / TEST-MANUAL | IS_TEST, MANUAL_TESTING env vars |
| device | iPhone / iPad | PORT (9999=iPhone, 8082=iPad) |
| component | MAC / iOS | fileName |

### Contracts

```
PRE: type in {log, error}
PRE: timestamp != null
PRE: fileName != null
PRE: functionName != null
PRE: message != undefined

POST: result.split(' | ').length = 8
POST: mode in {PROD, TEST, TEST-MANUAL}
POST: device in {iPhone, iPad}
POST: component in {MAC, iOS}
```

## TDD Commit Flow

| Commit | Deploy | Wait For | Evidence |
|--------|--------|----------|----------|
| test: | automated | error in log | commit code + log |
| impl: | automated | "Story complete" | commit code + log |
| refactor: | manual | "Story complete" | commit + delete traces |

## Protection

- Block --no-verify in Claude hooks
- TDD order: plan -> test -> impl -> refactor

## Files to Change

1. `scripts/mac-server.js` - log format with contracts
2. `scripts/hooks/post-commit.sh` - trace commit flow
3. `.claude/hooks/limit-main-agent.sh` - block --no-verify

## Implementation Steps

1. Create worktree from development
2. test: Add log format contracts (expect failure - old format has 6 parts)
3. impl: Fix formatLogLine to produce 8 parts
4. refactor: Clean up
5. Push, PR, merge
