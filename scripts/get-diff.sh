#!/bin/bash
cd "$(dirname "$0")/.."

# 1. Git status
echo "=== Git Status ==="
git status --short
echo ""

# 2. Git diff HEAD
echo "=== Git Diff HEAD ==="
git diff HEAD
echo ""

# 3. Untracked files with their content
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

# 4. Last 5 commits
echo "=== Last 5 commits ==="
git log --oneline -5
echo ""

# 5. Last 3 commits content
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
