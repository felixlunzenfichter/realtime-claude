#!/bin/bash
cd "$(dirname "$0")/.."

# 1. Git status
echo "=== Git Status ==="
git status --short
echo ""

# 2. Unstaged changes
echo "=== Unstaged Changes ==="
git diff
echo ""

# 3. Staged changes
echo "=== Staged Changes ==="
git diff --staged
echo ""

# 4. Untracked files with their content
echo "=== Untracked files ==="
git ls-files --others --exclude-standard | while read -r f; do
    if [ -f "$f" ]; then
        echo ""
        echo "new file: $f"
        echo "---"
        cat "$f"
        echo ""
    fi
done
echo ""

# 5. Last 5 commits
echo "=== Last 5 commits ==="
git log --oneline -5
echo ""

# 6. Last 3 commits content
echo "=== Commit 1 (HEAD) ==="
git show HEAD
echo ""
echo ""
echo "=== Commit 2 (HEAD~1) ==="
git show HEAD~1
echo ""
echo ""
echo "=== Commit 3 (HEAD~2) ==="
git show HEAD~2
