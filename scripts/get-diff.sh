#!/bin/bash
cd "$(dirname "$0")/.."

# 1. Git status
echo "=== Git Status ==="
git status --short
echo ""

# 2. Last 5 commits
echo "=== Last 5 commits ==="
git log --oneline -5
echo ""

# 3. Git diff HEAD
echo "=== Git Diff HEAD ==="
git diff HEAD
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

# 5. Previous commit content
echo "=== Previous commit content ==="
git show HEAD
