#!/bin/bash
# Read target repo from config file (one line: path to repo)
CONFIG_FILE="$HOME/.watched-repo"

if [ -f "$CONFIG_FILE" ]; then
    REPO_PATH=$(cat "$CONFIG_FILE")
else
    REPO_PATH="$(pwd)"
fi

cd "$REPO_PATH" || exit 1

# Active agents (sessions modified in last 5 min)
echo "=== ACTIVE AGENTS ==="
python3 << 'PYTHON' 2>/dev/null
import json, os, time

now = time.time()
cutoff = now - 300  # 5 minutes

agents = []

for proj_dir in os.listdir(os.path.expanduser("~/.claude/projects")):
    index_path = os.path.expanduser(f"~/.claude/projects/{proj_dir}/sessions-index.json")
    if os.path.exists(index_path):
        try:
            with open(index_path) as f:
                data = json.load(f)
            for entry in data.get("entries", []):
                mtime = entry.get("fileMtime", 0) / 1000
                if mtime > cutoff:
                    branch = entry.get("gitBranch", "unknown")
                    prompt = entry.get("firstPrompt", "")[:60].replace("\n", " ")
                    ago = int(now - mtime)
                    agents.append((ago, branch, prompt))
        except:
            pass

if agents:
    for ago, branch, prompt in sorted(agents):
        mins = ago // 60
        secs = ago % 60
        time_str = f"{mins}m{secs:02d}s" if mins else f"{secs}s"
        print(f"{time_str:>6} │ {branch:15} │ {prompt}...")
else:
    print("(none)")
PYTHON
echo ""

# Git tree with branches and commits
echo "=== GIT TREE ==="
git log --graph --pretty=format:'%h %ad%d %s' --date=format:'%b %d %H:%M' --abbrev-commit --all
echo ""
echo ""

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
