#!/bin/bash

UNPUSHED=$(git log --oneline @{upstream}..HEAD 2>/dev/null | wc -l | tr -d ' ')

if [ "$UNPUSHED" -gt 0 ]; then
    echo "❌ Push first. Unpushed: $UNPUSHED"
    git log --oneline @{upstream}..HEAD 2>/dev/null
    exit 1
fi

exit 0
