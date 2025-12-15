#!/bin/bash
cd "$(dirname "$0")/.."

# Branch status with ahead/behind count
echo "=== Branch Status ==="
git status -sb
echo ""

# Unstaged changes
echo "=== Unstaged Changes ==="
git diff --function-context
echo ""

# Staged changes
echo "=== Staged Changes ==="
git diff --staged --function-context
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

# Unified commit list showing local and remote positions
echo "=== Commits ==="
git fetch -q 2>/dev/null

# Get local and remote HEAD commit hashes
local_head=$(git rev-parse HEAD 2>/dev/null)
remote_head=$(git rev-parse origin/development 2>/dev/null || echo "")

# Get all commits and process them
git log --all -10 --format="%H|%ad %s %h" --date=format:'%b %d %H:%M' | while IFS='|' read -r commit_hash commit_line; do
    # Check if this commit is the remote HEAD
    if [ "$commit_hash" = "$remote_head" ]; then
        echo "=== REMOTE HEAD ==="
    fi

    # Check if this commit is the local HEAD
    if [ "$commit_hash" = "$local_head" ]; then
        echo "=== LOCAL HEAD ==="
    fi

    # Print the commit line
    echo "$commit_line"
done

# Latest 3 commits content with LOCAL/REMOTE markers
echo "=== Latest 3 Commits Content ==="
local_head=$(git rev-parse HEAD)

# Get the last 3 commit hashes with dates from all refs (local and remote)
commits=$(git log --all -3 --format="%H|%ad" --date=format:'%b %d %H:%M')

index=0
echo "$commits" | while IFS='|' read -r commit_hash commit_date; do
    # Check if this commit is reachable from local HEAD
    if git merge-base --is-ancestor "$commit_hash" "$local_head" 2>/dev/null; then
        marker="LOCAL"
    else
        marker="REMOTE"
    fi

    echo ""
    echo "=== Commit (HEAD~$index) ($commit_date) === $marker"
    git show --function-context "$commit_hash"
    echo ""

    index=$((index + 1))
done
