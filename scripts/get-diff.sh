#!/bin/bash
CONFIG_FILE="$HOME/.watched-repo"

if [ -f "$CONFIG_FILE" ]; then
    REPO_PATH=$(cat "$CONFIG_FILE")
else
    REPO_PATH="$(pwd)"
fi

cd "$REPO_PATH" || exit 1

python3 << 'PYTHON'
import json, os, time, subprocess, re

now = time.time()
cutoff = now - 300

def run(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, stderr=subprocess.DEVNULL, text=True).rstrip('\n')
    except:
        return ""

def time_ago(seconds):
    if seconds < 60:
        return f"{int(seconds)}s"
    elif seconds < 3600:
        return f"{int(seconds // 60)}m"
    elif seconds < 86400:
        return f"{int(seconds // 3600)}h"
    else:
        return f"{int(seconds // 86400)}d"

def get_hunks(filepath, staged=False):
    flag = "--cached " if staged else ""
    diff = run(f"git diff {flag}'{filepath}' 2>/dev/null")
    if not diff:
        return []

    hunks = []
    for line in diff.split('\n'):
        if line.startswith('+') and not line.startswith('+++'):
            match = re.search(r'(func |function |def |class |struct |enum |protocol |extension )\s*(\w+)', line)
            if match:
                hunks.append(f"+ {match.group(1).strip()} {match.group(2)}()")
        elif line.startswith('-') and not line.startswith('---'):
            match = re.search(r'(func |function |def |class |struct |enum |protocol |extension )\s*(\w+)', line)
            if match:
                hunks.append(f"- {match.group(1).strip()} {match.group(2)}()")

    return hunks[:5]

def get_commit_hunks(commit_hash, filepath):
    diff = run(f"git show {commit_hash} -- '{filepath}' 2>/dev/null")
    if not diff:
        return []

    hunks = []
    for line in diff.split('\n'):
        if line.startswith('+') and not line.startswith('+++'):
            match = re.search(r'(func |function |def |class |struct |enum |protocol |extension )\s*(\w+)', line)
            if match:
                hunks.append(f"+ {match.group(1).strip()} {match.group(2)}()")
        elif line.startswith('-') and not line.startswith('---'):
            match = re.search(r'(func |function |def |class |struct |enum |protocol |extension )\s*(\w+)', line)
            if match:
                hunks.append(f"- {match.group(1).strip()} {match.group(2)}()")

    return hunks[:5]

repo_name = os.path.basename(run("git rev-parse --show-toplevel") or "REPO")
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
                    prompt = entry.get("firstPrompt", "")[:30].replace("\n", " ").strip()
                    ago = int(now - mtime)
                    if agent_branch not in agents_by_branch:
                        agents_by_branch[agent_branch] = []
                    agents_by_branch[agent_branch].append((ago, prompt))
        except:
            pass

all_branches = [b.strip().lstrip('*+ ').strip() for b in run("git branch").split('\n') if b.strip()]
all_branches = [b for b in all_branches if b and not b.startswith('(')]

def get_branch_base(branch):
    remote = run(f"git rev-parse origin/{branch} 2>/dev/null")
    if remote:
        return f"origin/{branch}"
    return "origin/development"

def get_branch_ahead_count(branch):
    base = get_branch_base(branch)
    base_exists = run(f"git rev-parse {base} 2>/dev/null")
    if not base_exists:
        return 0
    return int(run(f"git rev-list {base}..{branch} --count") or "0")

def get_branch_unpushed(branch):
    base = get_branch_base(branch)
    base_exists = run(f"git rev-parse {base} 2>/dev/null")
    if not base_exists:
        return []
    ahead = int(run(f"git rev-list {base}..{branch} --count") or "0")
    if ahead == 0:
        return []

    unpushed = []
    log = run(f"git log {base}..{branch} --format='%H %h %s' --name-status")
    current_commit = None
    for line in log.split('\n'):
        if not line:
            continue
        if len(line) > 40 and ' ' in line[40:50]:
            parts = line.split(' ', 2)
            if len(parts) >= 3:
                full_hash, short_hash, msg = parts[0], parts[1], parts[2]
                commit_time = run(f"git log -1 --format='%ct' {full_hash}")
                ago = int(now - int(commit_time)) if commit_time else 0
                current_commit = {"hash": short_hash, "msg": msg[:50], "time": ago, "files": []}
                unpushed.append(current_commit)
        elif current_commit and line and line[0] in 'AMDRT':
            status_code = line[0]
            filepath = line[1:].strip()
            diff_stat = run(f"git show --numstat --format='' {current_commit['hash']} -- '{filepath}' 2>/dev/null")
            added, removed = 0, 0
            if diff_stat:
                parts = diff_stat.strip().split()
                if len(parts) >= 2:
                    added = int(parts[0]) if parts[0] != '-' else 0
                    removed = int(parts[1]) if parts[1] != '-' else 0
            hunks = get_commit_hunks(current_commit['hash'], filepath)
            current_commit["files"].append((status_code, filepath, added, removed, hunks))
    return unpushed

unstaged = []
staged = []
status = run("git status --porcelain")
for line in status.split('\n'):
    if not line.strip():
        continue
    index_status = line[0]
    worktree_status = line[1]
    filepath = line[3:]

    if index_status == '?' or worktree_status == '?':
        stat = run(f"wc -l < '{filepath}' 2>/dev/null") or "0"
        unstaged.append(("?", filepath, int(stat.strip()), 0, []))
    else:
        if worktree_status != ' ':
            diff_stat = run(f"git diff --numstat '{filepath}' 2>/dev/null")
            if diff_stat:
                parts = diff_stat.split()
                if len(parts) >= 2:
                    added = int(parts[0]) if parts[0] != '-' else 0
                    removed = int(parts[1]) if parts[1] != '-' else 0
                    hunks = get_hunks(filepath, staged=False)
                    code = "M" if worktree_status == 'M' else worktree_status
                    unstaged.append((code, filepath, added, removed, hunks))

        if index_status != ' ':
            diff_stat = run(f"git diff --cached --numstat '{filepath}' 2>/dev/null")
            if diff_stat:
                parts = diff_stat.split()
                if len(parts) >= 2:
                    added = int(parts[0]) if parts[0] != '-' else 0
                    removed = int(parts[1]) if parts[1] != '-' else 0
                    hunks = get_hunks(filepath, staged=True)
                    code = "A" if index_status == 'A' else ("D" if index_status == 'D' else "M")
                    staged.append((code, filepath, added, removed, hunks))
            elif index_status == 'A':
                stat = run(f"wc -l < '{filepath}' 2>/dev/null") or "0"
                staged.append(("A", filepath, int(stat.strip()), 0, []))

git_graph = run("git log --oneline --graph --all")

lines = []
lines.append(f"{repo_name}/")
lines.append("")

def print_branch_section(branch, is_current, agents, unstaged_files, staged_files, unpushed_commits, branch_ahead_count):
    marker = "★" if is_current else "○"
    if branch_ahead_count > 0:
        status_str = f"({branch_ahead_count} ahead)"
    else:
        status_str = "(up to date)"

    lines.append(f"{marker} {branch} {status_str}")

    sections = []
    if agents:
        sections.append(("Agents", agents))
    if unstaged_files:
        sections.append(("Unstaged", unstaged_files))
    if staged_files:
        sections.append(("Staged", staged_files))
    if unpushed_commits:
        sections.append(("Unpushed", unpushed_commits))

    if not sections:
        lines.append("└── (clean)")
        return

    for si, (section_name, section_data) in enumerate(sections):
        is_last_section = si == len(sections) - 1
        section_prefix = "└── " if is_last_section else "├── "
        child_prefix = "    " if is_last_section else "│   "

        lines.append(f"{section_prefix}{section_name}")

        if section_name == "Agents":
            for ai, (ago, prompt) in enumerate(sorted(section_data)):
                is_last = ai == len(section_data) - 1
                item_prefix = "└── " if is_last else "├── "
                lines.append(f"{child_prefix}{item_prefix}● {time_ago(ago)} \"{prompt}...\"")

        elif section_name in ("Unstaged", "Staged"):
            for fi, (code, filepath, added, removed, hunks) in enumerate(section_data):
                is_last_file = fi == len(section_data) - 1
                file_prefix = "└── " if is_last_file else "├── "
                file_child_prefix = "    " if is_last_file else "│   "

                if removed > 0:
                    stat_str = f"(+{added} -{removed})"
                else:
                    stat_str = f"(+{added})"

                lines.append(f"{child_prefix}{file_prefix}{code} {filepath} {stat_str}")

                for hi, hunk in enumerate(hunks):
                    is_last_hunk = hi == len(hunks) - 1
                    hunk_prefix = "└── " if is_last_hunk else "├── "
                    lines.append(f"{child_prefix}{file_child_prefix}{hunk_prefix}{hunk}")

        elif section_name == "Unpushed":
            for ci, commit in enumerate(section_data):
                is_last_commit = ci == len(section_data) - 1
                commit_prefix = "└── " if is_last_commit else "├── "
                commit_child_prefix = "    " if is_last_commit else "│   "

                lines.append(f"{child_prefix}{commit_prefix}{time_ago(commit['time'])} {commit['hash']} {commit['msg']}")

                for fi, (code, filepath, added, removed, hunks) in enumerate(commit["files"]):
                    is_last_file = fi == len(commit["files"]) - 1
                    file_prefix = "└── " if is_last_file else "├── "
                    file_child_prefix = "    " if is_last_file else "│   "

                    if removed > 0:
                        stat_str = f"(+{added} -{removed})"
                    else:
                        stat_str = f"(+{added})"

                    lines.append(f"{child_prefix}{commit_child_prefix}{file_prefix}{filepath} {stat_str}")

                    for hi, hunk in enumerate(hunks):
                        is_last_hunk = hi == len(hunks) - 1
                        hunk_prefix = "└── " if is_last_hunk else "├── "
                        lines.append(f"{child_prefix}{commit_child_prefix}{file_child_prefix}{hunk_prefix}{hunk}")

current_ahead = get_branch_ahead_count(current_branch)
current_unpushed = get_branch_unpushed(current_branch)

print_branch_section(
    current_branch,
    True,
    agents_by_branch.get(current_branch, []),
    unstaged,
    staged,
    current_unpushed,
    current_ahead
)

for branch in sorted(all_branches):
    if branch != current_branch:
        lines.append("")
        branch_ahead = get_branch_ahead_count(branch)
        branch_unpushed = get_branch_unpushed(branch)
        print_branch_section(
            branch,
            False,
            agents_by_branch.get(branch, []),
            [],
            [],
            branch_unpushed,
            branch_ahead
        )

lines.append("")
lines.append("─" * 40)
lines.append("")

for line in git_graph.split('\n'):
    if line.strip():
        lines.append(line)

print('\n'.join(lines))
PYTHON
