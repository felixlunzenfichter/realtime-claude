# Block --no-verify

## Goal
Prevent --no-verify from bypassing git hooks via Claude Code.

## Approach
Add pre() guard in limit-main-agent.sh that checks Bash commands for --no-verify.

## Contract
PRE: git commands must not contain --no-verify
