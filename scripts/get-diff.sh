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

def run(cmd, cwd=None):
    try:
        return subprocess.check_output(cmd, shell=True, stderr=subprocess.DEVNULL, text=True, cwd=cwd).rstrip('\n')
    except:
        return ""

def get_diff_summary(diff_output):
    summary = []
    added = 0
    removed = 0
    for line in diff_output.split('\n'):
        if line.startswith('@@'):
            match = re.search(r'@@ .* @@ (.*)', line)
            if match and match.group(1).strip():
                ctx = match.group(1).strip()[:45]
                summary.append(f"@ {ctx}")
        elif line.startswith('+') and not line.startswith('+++'):
            added += 1
            if re.search(r'^\+\s*(def |func |fn |function )', line):
                func_match = re.search(r'(def |func |fn |function )(\w+)', line)
                if func_match:
                    summary.insert(0, f"+ {func_match.group(1)}{func_match.group(2)}()")
            elif re.search(r'^\+\s*(class |struct |enum |interface )', line):
                class_match = re.search(r'(class |struct |enum |interface )(\w+)', line)
                if class_match:
                    summary.insert(0, f"+ {class_match.group(1)}{class_match.group(2)}")
        elif line.startswith('-') and not line.startswith('---'):
            removed += 1
    seen = set()
    unique = []
    for s in summary[:6]:
        if s not in seen:
            seen.add(s)
            unique.append(s)
    return unique, added, removed

def get_file_summary(diff_output):
    files = {}
    current_file = None
    for line in diff_output.split('\n'):
        if line.startswith('diff --git'):
            parts = line.split(' b/')
            if len(parts) > 1:
                current_file = parts[-1]
                files[current_file] = {'added': 0, 'removed': 0, 'summary': []}
        elif current_file:
            if line.startswith('@@'):
                match = re.search(r'@@ .* @@ (.*)', line)
                if match and match.group(1).strip():
                    ctx = match.group(1).strip()[:40]
                    files[current_file]['summary'].append(f"@ {ctx}")
            elif line.startswith('+') and not line.startswith('+++'):
                files[current_file]['added'] += 1
                if re.search(r'^\+\s*(def |func |fn |function )', line):
                    func_match = re.search(r'(def |func |fn |function )(\w+)', line)
                    if func_match:
                        files[current_file]['summary'].insert(0, f"+ {func_match.group(1)}{func_match.group(2)}()")
                elif re.search(r'^\+\s*(class |struct |enum |interface )', line):
                    class_match = re.search(r'(class |struct |enum |interface )(\w+)', line)
                    if class_match:
                        files[current_file]['summary'].insert(0, f"+ {class_match.group(1)}{class_match.group(2)}")
            elif line.startswith('-') and not line.startswith('---'):
                files[current_file]['removed'] += 1
    for f in files:
        seen = set()
        unique = []
        for s in files[f]['summary'][:4]:
            if s not in seen:
                seen.add(s)
                unique.append(s)
        files[f]['summary'] = unique
    return files

def get_worktree_changes(wt_path):
    staged = {}
    unstaged = {}
    untracked = {}

    status = run("git status --porcelain", cwd=wt_path)
    for line in status.split('\n'):
        if not line.strip():
            continue
        index_status = line[0]
        worktree_status = line[1]
        filepath = line[3:]

        if index_status == '?':
            content = run(f"cat '{filepath}' 2>/dev/null", cwd=wt_path) or ""
            line_count = len([l for l in content.split('\n') if l])
            untracked[filepath] = {'added': line_count, 'removed': 0, 'summary': []}
        else:
            if index_status != ' ' and index_status != '?':
                diff = run(f"git diff --cached '{filepath}' 2>/dev/null", cwd=wt_path)
                if diff:
                    summary, added, removed = get_diff_summary(diff)
                    staged[filepath] = {'added': added, 'removed': removed, 'summary': summary}
            if worktree_status != ' ' and worktree_status != '?':
                diff = run(f"git diff '{filepath}' 2>/dev/null", cwd=wt_path)
                if diff:
                    summary, added, removed = get_diff_summary(diff)
                    unstaged[filepath] = {'added': added, 'removed': removed, 'summary': summary}

    return staged, unstaged, untracked

def format_ago(seconds):
    if seconds < 60:
        return f"{int(seconds)}s"
    elif seconds < 3600:
        return f"{int(seconds // 60)}m"
    elif seconds < 86400:
        return f"{int(seconds // 3600)}h"
    else:
        return f"{int(seconds // 86400)}d"

def get_unpushed_commits(wt_path, remote_base):
    commits = []
    remote_base_hash = run(f"git rev-parse {remote_base} 2>/dev/null", cwd=wt_path)
    local_head = run("git rev-parse HEAD", cwd=wt_path)

    if remote_base_hash and local_head != remote_base_hash:
        ahead_count = run(f"git rev-list --count {remote_base}..HEAD 2>/dev/null", cwd=wt_path) or "0"
        if int(ahead_count) > 0:
            commit_hashes = run(f"git rev-list {remote_base}..HEAD 2>/dev/null", cwd=wt_path).split('\n')
            for commit_hash in commit_hashes:
                if not commit_hash.strip():
                    continue
                short_hash = run(f"git rev-parse --short {commit_hash}", cwd=wt_path)
                subject = run(f"git log -1 --format='%s' {commit_hash}", cwd=wt_path)
                commit_time = run(f"git log -1 --format='%ct' {commit_hash}", cwd=wt_path)
                ago = format_ago(now - int(commit_time)) if commit_time else ""
                diff_output = run(f"git show {commit_hash} --format='' --no-color", cwd=wt_path)
                summary, added, removed = get_diff_summary(diff_output)
                commits.append({
                    'hash': short_hash,
                    'subject': subject,
                    'ago': ago,
                    'added': added,
                    'removed': removed,
                    'summary': summary
                })
    return commits

current_branch = run("git rev-parse --abbrev-ref HEAD") or "unknown"
repo_path = run("pwd")

agents_by_branch = {}
worktree_paths = {}

worktree_list = run("git worktree list --porcelain")
for block in worktree_list.split('\n\n'):
    wt_path = None
    wt_branch = None
    for line in block.split('\n'):
        if line.startswith('worktree '):
            wt_path = line[9:]
        if line.startswith('branch refs/heads/'):
            wt_branch = line[18:]
    if wt_path and wt_branch:
        worktree_paths[wt_branch] = wt_path

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

base_branch = "development"
remote_base = f"origin/{base_branch}"

lines = []

all_branches = set(agents_by_branch.keys()) | set(worktree_paths.keys())
if current_branch not in all_branches:
    all_branches.add(current_branch)

for br in sorted(all_branches, key=lambda b: (b != current_branch, b)):
    agents = agents_by_branch.get(br, [])
    marker = "★" if br == current_branch else "○"
    wt_path = worktree_paths.get(br, repo_path if br == current_branch else "")
    path_short = wt_path.replace(os.path.expanduser("~"), "~") if wt_path else ""

    ahead_count = "0"
    if wt_path:
        ahead_count = run(f"git rev-list --count {remote_base}..HEAD 2>/dev/null", cwd=wt_path) or "0"

    ahead_info = f" ({ahead_count} ahead)" if int(ahead_count) > 0 else ""
    lines.append(f"{marker} {br}{ahead_info} @ {path_short}")

    for ago, prompt in sorted(agents):
        if ago < 60:
            time_str = f"{ago}s"
        else:
            time_str = f"{ago // 60}m{ago % 60:02d}s"
        lines.append(f"  ● {time_str} \"{prompt}...\"")

    if wt_path:
        staged, unstaged, untracked = get_worktree_changes(wt_path)

        if unstaged or untracked:
            lines.append("")
            lines.append("── unstaged ──")
            for filepath, info in unstaged.items():
                lines.append(f"  {filepath} (+{info['added']} -{info['removed']})")
                for s in info['summary']:
                    lines.append(f"  {s}")
            for filepath, info in untracked.items():
                lines.append(f"  {filepath} (new +{info['added']})")

        if staged:
            lines.append("")
            lines.append("── staged ──")
            for filepath, info in staged.items():
                lines.append(f"  {filepath} (+{info['added']} -{info['removed']})")
                for s in info['summary']:
                    lines.append(f"  {s}")

        unpushed = get_unpushed_commits(wt_path, remote_base)
        if unpushed:
            lines.append("")
            lines.append("── unpushed ──")
            for commit in unpushed:
                lines.append("")
                lines.append(f"* {commit['ago']} {commit['hash']} {commit['subject']} (+{commit['added']} -{commit['removed']})")
                for s in commit['summary']:
                    lines.append(f"  {s}")

    lines.append("")

git_graph = run(f"git log {remote_base} --graph --pretty=format:'%cr %h %s' --abbrev-commit -30 2>/dev/null")
if not git_graph:
    git_graph = run("git log --graph --pretty=format:'%cr %h %s' --abbrev-commit -30")

if git_graph:
    lines.append("── history ──")
    for graph_line in git_graph.split('\n'):
        lines.append(graph_line)

print('\n'.join(lines))
PYTHON
