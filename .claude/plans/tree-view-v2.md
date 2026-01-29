# Tree View v2

## Final Design

```
REPO/
│
┌─ GROWING ────────────────────────────────────┐
│                                              │
│  ★ BRANCH_A (N ahead)                        │
│    ├─ Agents                                 │
│    │    ● TIME "PROMPT"                      │
│    ├─ Unstaged                               │
│    │    FILE (+N)                            │
│    │      + func()                           │
│    │      - func()                           │
│    ├─ Staged                                 │
│    │    FILE (+N -M)                         │
│    │      - func()                           │
│    └─ Unpushed                               │
│         TIME HASH MSG                        │
│           FILE (+N -M)                       │
│             + func()                         │
│                                              │
│  ○ BRANCH_B (N ahead)                        │
│    ├─ Agents                                 │
│    │    ● TIME "PROMPT"                      │
│    ├─ Unstaged                               │
│    │    FILE (+N)                            │
│    └─ Unpushed                               │
│         TIME HASH MSG                        │
│           FILE (+N -M)                       │
│                                              │
│  ○ BRANCH_C (up to date)                     │
│    └─ (clean)                                │
│                                              │
└──────────────────────────────────────────────┘
│
┌─ STABLE (development) ───────────────────────┐
│                                              │
│  TIME HASH MSG                               │
│  TIME HASH MSG                               │
│  ...                                         │
│                                              │
└──────────────────────────────────────────────┘
```

## Data Fields Per Section

| Section | Time | Hash | Msg | File | +N | -M | Hunks |
|---------|------|------|-----|------|----|----|-------|
| Agents | ✓ | | | | | | |
| Unstaged | | | | ✓ | ✓ | | ✓ |
| Staged | | | | ✓ | ✓ | ✓ | ✓ |
| Unpushed | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Stable | ✓ | ✓ | ✓ | | | | |

## Symbols

| Symbol | Meaning |
|--------|---------|
| `★` | Current worktree |
| `○` | Other worktree |
| `●` | Active agent |
| `(N ahead)` | Unpushed commits |
| `(up to date)` | No unpushed |
| `(clean)` | No changes |
| `+ func()` | Added function/class |
| `- func()` | Removed function/class |

## Omission Rules

- Empty section → don't show
- All empty → show `(clean)`

## Implementation Steps

### Step 1 (CURRENT): List worktrees with branch names

Output after step 1:
```
realtime-claude/
│
┌─ GROWING ────────────────────────────────────┐
│                                              │
│  ★ development                               │
│                                              │
│  ○ inline-diffs-v2                           │
│                                              │
└──────────────────────────────────────────────┘
```

File to modify: `scripts/get-diff.sh`

### Future Steps (one at a time)
2. Add ahead count per worktree
3. Add agents section per worktree
4. Add unstaged section (files + line counts)
5. Add staged section (files + line counts)
6. Add unpushed commits (time, hash, msg)
7. Add files per unpushed commit
8. Add hunks for unstaged files
9. Add hunks for staged files
10. Add hunks for unpushed commit files
11. Add stable section (time, hash, msg only)

## Git Commands

| Data | Command |
|------|---------|
| Worktrees | `git worktree list` |
| Current branch | `git rev-parse --abbrev-ref HEAD` |
| Ahead count | `git rev-list origin/development..BRANCH --count` |
| Unstaged files | `git diff --name-only` |
| Staged files | `git diff --cached --name-only` |
| Untracked files | `git ls-files --others --exclude-standard` |
| Unstaged stats | `git diff --numstat FILE` |
| Staged stats | `git diff --cached --numstat FILE` |
| Unstaged hunks | `git diff -U0 FILE` |
| Staged hunks | `git diff --cached -U0 FILE` |
| Unpushed commits | `git log origin/development..HEAD --format='%ar %h %s'` |
| Commit files | `git show HASH --stat --format=""` |
| Commit hunks | `git show HASH -U0` |
| Agents | `~/.claude/projects/*/sessions-index.json` |
| Stable commits | `git log origin/development --format='%ar %h %s' -10` |
