# Plan: Enforce TDD Traces in commit-msg Hook

## Goal
Modify commit-msg hook to require trace files as evidence of TDD compliance.

## Trace Files
- `.test-trace-failing` - Output from failed test (RED phase evidence)
- `.test-passed-automated` - Marker for automated test pass
- `.test-passed-manual` - Marker for manual test pass

## Enforcement Rules

### plan: commit
- Requires: automated test passes (marker exists)
- Creates: plan file in `.claude/plans/`

### test: commit (RED phase)
- Requires: `.test-trace-failing` file in staged diff
- This proves the test was written and ran RED

### impl: commit (GREEN phase)
- Requires: `.test-passed-automated` file exists
- This proves the implementation made tests pass

### refactor: commit (CLEANUP)
- Requires: BOTH markers exist (automated + manual passed)
- Requires: Deletion of trace files AND plan file in diff
- Files deleted: `.test-trace-failing`, `.test-passed-automated`, `.test-passed-manual`, plan file

## Implementation

Modify `scripts/hooks/commit-msg.sh`:

1. After TYPE detection, before Claude check
2. Use `git diff --cached --name-status` to see staged files
3. Check for required traces based on TYPE
4. Fail with clear error if missing

## Success Criteria
- Cannot make test: commit without failing trace
- Cannot make impl: commit without passing marker
- Cannot make refactor: commit without cleanup
