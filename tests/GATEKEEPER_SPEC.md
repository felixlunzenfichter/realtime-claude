# Gatekeeper Test Specification

## TEST 1: Plan requires acceptance
BEHAVIOR: plan: commit cannot push until ExitPlanMode creates .plan-accepted
TIMING: Push must fail immediately without .plan-accepted
FAIL IF: Push succeeds without .plan-accepted file containing correct hash

## TEST 2: Acceptance enables push
BEHAVIOR: After ExitPlanMode, .plan-accepted contains HEAD hash, push succeeds
TIMING: Push should succeed immediately after acceptance
FAIL IF: Push fails after valid .plan-accepted exists

## TEST 3: Test/impl/refactor auto-push
BEHAVIOR: test:/impl:/refactor: commits push immediately (tests disabled)
TIMING: Push happens automatically in post-commit
FAIL IF: Push requires manual intervention

## TEST 4: Order enforcement
BEHAVIOR: Commits must follow order: plan → test → impl → refactor
TIMING: commit-msg rejects out-of-order commits
FAIL IF: impl: allowed before test:, or test: allowed before plan:
