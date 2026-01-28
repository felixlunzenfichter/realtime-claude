#!/bin/bash
CONFIG_FILE="$HOME/.watched-repo"

if [ -f "$CONFIG_FILE" ]; then
    REPO_PATH=$(cat "$CONFIG_FILE")
else
    REPO_PATH="$(pwd)"
fi

cd "$REPO_PATH" || exit 1

python3 << 'PYTHON'
import json, os, time, subprocess

now = time.time()
cutoff = now - 300

def run(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, stderr=subprocess.DEVNULL, text=True).rstrip('\n')
    except:
        return ""

current_branch = run("git rev-parse --abbrev-ref HEAD") or "unknown"

agents_by_branch = {}
for proj_dir in os.listdir(os.path.expanduser("~/.claude/projects")):
    index_path = os.path.expanduser(f"~/.claude/projects/{proj_dir}/sessions-index.json")
    if os.path.exists(index_path):
        try:
            with open(index_path) as f:
                data = json.load(f)
            for entry in data.get("entries", []):
                mtime = entry.get("fileMtime", 0) / 1000
                agent_branch = entry.get("gitBranch", "") or "unknown"
                if mtime > cutoff:
                    prompt = entry.get("firstPrompt", "")[:40].replace("\n", " ").strip()
                    ago = int(now - mtime)
                    if agent_branch not in agents_by_branch:
                        agents_by_branch[agent_branch] = []
                    agents_by_branch[agent_branch].append((ago, prompt))
        except:
            pass

branch = current_branch
remote_head = run("git rev-parse origin/" + branch + " 2>/dev/null")
local_head = run("git rev-parse HEAD")

commits = []
log = run("git log --format='%h %d %s'")
for line in log.split('\n'):
    if line.strip():
        commits.append(line.strip())

working = []
status = run("git status --porcelain")
for line in status.split('\n'):
    if not line.strip():
        continue
    code = line[:2]
    filepath = line[3:]

    if code[0] == '?' or code[1] == '?':
        stat = run(f"wc -l < '{filepath}' 2>/dev/null") or "0"
        working.append(f"? {filepath} (+{stat.strip()})")
    else:
        diff_stat = run(f"git diff --numstat '{filepath}' 2>/dev/null")
        if diff_stat:
            parts = diff_stat.split()
            if len(parts) >= 2:
                added, removed = parts[0], parts[1]
                working.append(f"M {filepath} (+{added} -{removed})")
        else:
            diff_stat = run(f"git diff --cached --numstat '{filepath}' 2>/dev/null")
            if diff_stat:
                parts = diff_stat.split()
                if len(parts) >= 2:
                    added, removed = parts[0], parts[1]
                    working.append(f"M {filepath} (+{added} -{removed})")

lines = []

for br in sorted(agents_by_branch.keys(), key=lambda b: (b != current_branch, b)):
    agents = agents_by_branch[br]
    marker = "★" if br == current_branch else "○"
    lines.append(f"├─ {marker} {br}")
    for ago, prompt in sorted(agents):
        if ago < 60:
            time_str = f"{ago}s"
        else:
            time_str = f"{ago // 60}m{ago % 60:02d}s"
        lines.append(f"│  ├─ ● {time_str} \"{prompt}...\"")
    lines.append("│")

if working:
    lines.append("├─ Working")
    for i, w in enumerate(working):
        prefix = "│  └─ " if i == len(working) - 1 else "│  ├─ "
        lines.append(prefix + w)
    lines.append("│")

if commits:
    for i, c in enumerate(commits):
        prefix = "└─ " if i == len(commits) - 1 else "├─ "
        lines.append(prefix + c)
else:
    lines.append("└─ (no commits)")

print('\n'.join(lines))
PYTHON
