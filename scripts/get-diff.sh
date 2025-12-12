#!/bin/bash
cd "$(dirname "$0")/.."

# Show staged + unstaged changes
git diff HEAD

# Show untracked files with their content
echo ""
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
