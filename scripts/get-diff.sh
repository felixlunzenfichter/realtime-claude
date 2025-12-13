#!/bin/bash
cd "$(dirname "$0")/.."

# Branch status with ahead/behind count
echo "=== Branch Status ==="
git status -sb
echo ""

# Unstaged changes
echo "=== Unstaged Changes ==="
git diff
echo ""

# Staged changes
echo "=== Staged Changes ==="
git diff --staged
echo ""

# Untracked files with their content
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

# Last 5 commits
echo "=== Last 5 commits ==="
git log --oneline -5
echo ""

# Last 3 commits content
echo "=== Commit (HEAD) ==="
git show HEAD
echo ""
echo ""
echo "=== Commit (HEAD~1) ==="
git show HEAD~1
echo ""
echo ""
echo "=== Commit (HEAD~2) ==="
git show HEAD~2
