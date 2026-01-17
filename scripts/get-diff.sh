#!/bin/bash
# Read target repo from config file (one line: path to repo)
CONFIG_FILE="$HOME/.watched-repo"

if [ -f "$CONFIG_FILE" ]; then
    REPO_PATH=$(cat "$CONFIG_FILE")
else
    REPO_PATH="$(pwd)"
fi

cd "$REPO_PATH" || exit 1

# Branch status with ahead/behind count
echo "=== Branch Status ==="
repo_name=$(basename -s .git "$(git config --get remote.origin.url)" 2>/dev/null || basename "$(pwd)")
git status -sb | sed "s/^## /$repo_name\//"
echo ""

# Unstaged changes
echo "=== Unstaged Changes ==="
git diff --function-context
echo ""

# Staged changes
echo "=== Staged Changes ==="
git diff --staged --function-context
echo ""

# Untracked files with their content (max 5000 bytes per file)
echo "=== Untracked files ==="
git ls-files --others --exclude-standard | while read -r f; do
    if [ -f "$f" ]; then
        size=$(wc -c < "$f")
        echo ""
        echo "new file: $f"
        echo "---"
        if [ "$size" -lt 5000 ]; then
            cat "$f"
        else
            echo "(file too large: $size bytes)"
        fi
        echo ""
    fi
done
echo ""

# Commits
echo "=== Commits ==="
git fetch -q 2>/dev/null
local_head=$(git rev-parse HEAD 2>/dev/null)
remote_head=$(git rev-parse origin/development 2>/dev/null || echo "")

git log --all -10 --format="%H|%ad %s %h" --date=format:'%b %d %H:%M' | while IFS='|' read -r commit_hash commit_line; do
    if [ "$commit_hash" = "$remote_head" ]; then
        echo "=== REMOTE HEAD ==="
    fi
    if [ "$commit_hash" = "$local_head" ]; then
        echo "=== LOCAL HEAD ==="
    fi
    echo "$commit_line"
done

echo "=== Last Commit ==="
git show -1 --format="%h %ad %s" --date=format:'%b %d %H:%M'
