#!/bin/bash
CONFIG_FILE="$HOME/.watched-repo"

if [ -f "$CONFIG_FILE" ]; then
    REPO_PATH=$(cat "$CONFIG_FILE")
else
    REPO_PATH="$(pwd)"
fi

cd "$REPO_PATH" || exit 1

python3 << 'PYTHON'
import subprocess

def run(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, stderr=subprocess.DEVNULL, text=True).rstrip('\n')
    except:
        return ""

current_branch = run("git rev-parse --abbrev-ref HEAD") or "unknown"
dev_head = run("git rev-parse origin/development 2>/dev/null")
local_head = run("git rev-parse HEAD")

unpushed_commits = []
if dev_head and current_branch != "development":
    log = run(f"git log origin/development..HEAD --format='%h|%s'")
    for line in log.split('\n'):
        if line.strip() and '|' in line:
            hash_part, msg = line.split('|', 1)
            unpushed_commits.append((hash_part.strip(), msg.strip()))

lines = []

if unpushed_commits:
    lines.append(f"├─ ★ {current_branch} ({len(unpushed_commits)} ahead)")
    lines.append("│")

    for i, (commit_hash, msg) in enumerate(unpushed_commits):
        is_last_commit = (i == len(unpushed_commits) - 1)
        connector = "└─" if is_last_commit else "├─"
        cont = " " if is_last_commit else "│"

        lines.append(f"│  {connector} {commit_hash}: \"{msg}\"")

        diff = run(f"git show {commit_hash} --format='' --no-color -- | head -50")
        if diff:
            diff_lines = diff.split('\n')
            for dl in diff_lines:
                if dl.startswith('+') and not dl.startswith('+++'):
                    lines.append(f"│  {cont}    + {dl[1:60]}")
                elif dl.startswith('-') and not dl.startswith('---'):
                    lines.append(f"│  {cont}    - {dl[1:60]}")

        if not is_last_commit:
            lines.append("│  │")

    lines.append("│")

status = run("git status --porcelain")
working_files = []
for line in status.split('\n'):
    if line.strip():
        filepath = line[3:]
        working_files.append(filepath)

if working_files:
    lines.append("├─ Working")

    for i, filepath in enumerate(working_files):
        is_last = (i == len(working_files) - 1)
        connector = "└─" if is_last else "├─"
        cont = " " if is_last else "│"

        lines.append(f"│  {connector} {filepath}")

        diff = run(f"git diff HEAD -- '{filepath}' 2>/dev/null | head -30")
        if not diff:
            diff = run(f"git diff --cached -- '{filepath}' 2>/dev/null | head -30")

        if diff:
            diff_lines = diff.split('\n')
            for dl in diff_lines:
                if dl.startswith('+') and not dl.startswith('+++'):
                    lines.append(f"│  {cont}    + {dl[1:60]}")
                elif dl.startswith('-') and not dl.startswith('---'):
                    lines.append(f"│  {cont}    - {dl[1:60]}")

    lines.append("│")

dev_log = run("git log origin/development --format='%h %s' -5")
if dev_log:
    dev_commits = dev_log.split('\n')
    for i, c in enumerate(dev_commits):
        if c.strip():
            is_last = (i == len(dev_commits) - 1)
            prefix = "└─" if is_last else "├─"
            lines.append(f"{prefix} {c.strip()}")

print('\n'.join(lines))
PYTHON
