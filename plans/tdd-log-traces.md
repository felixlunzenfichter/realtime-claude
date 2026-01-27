# Plan: TDD Log Traces

## Goal
Commit log files as trace evidence. No marker files, no separate check script.

## Architecture

```
private/logs/N.json  <- session logs (committed as trace evidence)
```

### Log Content
- Error entries: `"type":"error"` -> test FAILED
- Success marker: `"Story complete"` -> test PASSED

### Commit Flow

| Type | Deploy | Wait for | Then |
|------|--------|----------|------|
| test: | automated | error in log | commit code + log |
| impl: | automated | "Story complete" | commit code + log |
| refactor: | manual | "Story complete" | commit code + log, delete traces |

## Implementation

post-commit.sh:
1. Get commit type from message (test:/impl:/refactor:)
2. Deploy appropriate test (automated or manual)
3. Poll log for expected result
4. Stage and amend commit with log file
5. On refactor: delete trace logs

## Files Changed
- `scripts/hooks/post-commit.sh` (UPDATE)
