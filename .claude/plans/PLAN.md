# Plan: Real Plans Directory

Replace symlink with real directory so plans can be committed.

## Problem
- .claude/plans was a symlink to ~/.claude/plans
- Git only tracks the symlink, not the content
- Plans outside repo, can't be committed

## Solution
- Delete symlink
- Create real .claude/plans/ directory
- Add .gitkeep to track empty directory
- Plans written here are tracked by git
