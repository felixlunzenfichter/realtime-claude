#!/bin/bash

set -euo pipefail

start_node_process() {
    local PROCESS_NAME=$1
    local DISPLAY_NAME=$2
    local PREFIX=$3

    echo "🚀 Starting $DISPLAY_NAME..."
    (node $PROCESS_NAME 2>&1 | sed "s/^/[$PREFIX] /") &
    local PID=$!

    echo "⏳ Waiting for $DISPLAY_NAME to start..."
    for i in {1..100}; do
        if pgrep -f "node $PROCESS_NAME" > /dev/null; then
            ELAPSED=$(echo "scale=1; $i * 0.1" | bc)
            echo "✅ $DISPLAY_NAME started in ~${ELAPSED}s (PID: $PID)"
            return 0
        fi
        sleep 0.1
    done

    echo "❌ $DISPLAY_NAME failed to start after 10 seconds"
    exit 1
}

trap 'echo ""; echo "💥 FATAL: Mac server deployment failed at line $LINENO"; echo "Command: $BASH_COMMAND"; echo "Exit code: $?"; echo ""; exit 1' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "DEPLOY MAC SERVER"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Stop existing Mac server
if pgrep -f "node scripts/mac-server.js" > /dev/null; then
    echo "   Stopping existing mac-server.js..."
    pkill -f "node scripts/mac-server.js" 2>/dev/null || true
    wait 2>/dev/null || true
    echo "   ✅ Stopped"
fi

# Clean up port 8082 if in use
if lsof -ti:8082 > /dev/null 2>&1; then
    echo "   Cleaning up port 8082..."
    lsof -ti:8082 | xargs kill -9
    echo "   ✅ Port cleaned"
fi

echo ""

# Start Mac server
start_node_process "scripts/mac-server.js" "Mac server" "SERVER"
SERVER_PID=$!

echo ""
echo "✅ Mac server deployed successfully (PID: $SERVER_PID)"
echo ""
