#!/bin/bash
CONFIG_FILE="$HOME/.watched-repo"

if [ -f "$CONFIG_FILE" ]; then
    REPO_PATH=$(cat "$CONFIG_FILE")
else
    REPO_PATH="$(pwd)"
fi

cd "$REPO_PATH" || exit 1

current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

get_agents_for_branch() {
    local target_branch="$1"
    python3 << PYTHON 2>/dev/null
import json, os, time

now = time.time()
cutoff = now - 300

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
                    if branch == "$target_branch":
                        prompt = entry.get("firstPrompt", "")[:40].replace("\n", " ")
                        ago = int(now - mtime)
                        agents.append((ago, prompt))
        except:
            pass

for ago, prompt in sorted(agents):
    mins = ago // 60
    secs = ago % 60
    if mins:
        time_str = f"{mins}m{secs:02d}s"
    else:
        time_str = f"{secs}s"
    print(f'[agent: {time_str} ago "{prompt}..."]')
PYTHON
}

echo "=== Tree ==="
echo ""

has_working_changes=false
working_status=$(git status --porcelain 2>/dev/null)
if [ -n "$working_status" ]; then
    has_working_changes=true
fi

if [ "$has_working_changes" = true ]; then
    agent_tags=$(get_agents_for_branch "$current_branch")
    if [ -n "$agent_tags" ]; then
        echo "* (working) $agent_tags"
    else
        echo "* (working)"
    fi

    echo "$working_status" | while read -r line; do
        echo "  $line"
    done
    echo ""

    staged_diff=$(git diff --staged --function-context 2>/dev/null)
    unstaged_diff=$(git diff --function-context 2>/dev/null)

    if [ -n "$staged_diff" ]; then
        echo "$staged_diff" | sed 's/^/  /'
        echo ""
    fi

    if [ -n "$unstaged_diff" ]; then
        echo "$unstaged_diff" | sed 's/^/  /'
        echo ""
    fi

    git ls-files --others --exclude-standard | while read -r f; do
        if [ -f "$f" ]; then
            size=$(wc -c < "$f")
            echo "  new file: $f"
            if [ "$size" -lt 5000 ]; then
                cat "$f" | sed 's/^/  /'
            else
                echo "  (file too large: $size bytes)"
            fi
            echo ""
        fi
    done
fi

git fetch -q 2>/dev/null
remote_head=$(git rev-parse origin/development 2>/dev/null || echo "")

unpushed_commits=$(git log --pretty=format:"%H %h %s" origin/development..HEAD 2>/dev/null)

if [ -n "$unpushed_commits" ]; then
    echo "$unpushed_commits" | while read -r full_hash short_hash message; do
        echo "* $short_hash $message"

        parent=$(git rev-parse "${full_hash}^" 2>/dev/null)
        if [ -n "$parent" ]; then
            diff_output=$(git diff --function-context "$parent" "$full_hash" 2>/dev/null)
            if [ -n "$diff_output" ]; then
                echo "$diff_output" | sed 's/^/  /'
                echo ""
            fi
        fi
    done
fi

dev_agent_tags=$(get_agents_for_branch "development")
if [ -n "$dev_agent_tags" ]; then
    echo "──── origin/development ──── $dev_agent_tags"
else
    echo "──── origin/development ────"
fi
echo ""

git log --pretty=format:"* %h %s" origin/development -10 2>/dev/null
echo ""
