# Plan: Strict TDD Commit Order

## Rule

| Current | Previous must be |
|---------|------------------|
| plan: | (none - first commit only) |
| test: | plan: |
| impl: | test: |
| refactor: | impl: |

One cycle per branch: plan → test → impl → refactor → merge
