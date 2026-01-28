#!/bin/bash

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

LOG_FILE="/tmp/hook-coordinator.log"

BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null || echo "unknown")

# Log
{
    echo "════════════════════════════════════════════════════════════════"
    echo "TIME: $(date)"
    echo "TOOL: $TOOL_NAME"
    echo "CWD: $CWD"
    echo "BRANCH: $BRANCH"
} >> "$LOG_FILE"

# =============================================================================
# RULE: ExitPlanMode auto-accepts the plan
# =============================================================================
if [ "$TOOL_NAME" = "ExitPlanMode" ]; then
    echo "$BRANCH" > "$CWD/.plan-accepted"
    echo "RESULT: ALLOWED (ExitPlanMode - plan accepted for $BRANCH)" >> "$LOG_FILE"
    echo "════════════════════════════════════════════════════════════════" >> "$LOG_FILE"
    echo "✅ Plan accepted for branch: $BRANCH" >&2
    exit 0
fi

# =============================================================================
# Everything else allowed (restrictions disabled for now)
# =============================================================================
echo "RESULT: ALLOWED ($TOOL_NAME)" >> "$LOG_FILE"
echo "════════════════════════════════════════════════════════════════" >> "$LOG_FILE"
exit 0
