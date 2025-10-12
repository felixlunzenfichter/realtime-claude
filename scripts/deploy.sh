#!/bin/bash

set -euo pipefail

DEVICE_TYPE=${1:-iphone}

BACKGROUND_PIDS=()
CLEANUP_DONE=false

cleanup() {
    if [ "$CLEANUP_DONE" = true ]; then
        return
    fi
    CLEANUP_DONE=true

    echo ""
    echo "🧹 Cleaning up background processes..."

    for pid in "${BACKGROUND_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "   Stopping PID $pid"
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done

    pkill -TERM -f "node scripts/test-system.js" 2>/dev/null || true
    pkill -TERM -f "node scripts/mac-server.js" 2>/dev/null || true

    sleep 0.3

    for pid in "${BACKGROUND_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
    done

    echo "✅ Cleanup complete"
}

trap cleanup SIGINT

start_node_process() {
    local PROCESS_NAME=$1
    local DISPLAY_NAME=$2
    local PREFIX=$3

    echo "   Starting $DISPLAY_NAME..."
    (node $PROCESS_NAME 2>&1 | sed "s/^/[$PREFIX] /") &
    local PID=$!
    BACKGROUND_PIDS+=($PID)

    for i in {1..100}; do
        if pgrep -f "node $PROCESS_NAME" > /dev/null; then
            ELAPSED=$(echo "scale=1; $i * 0.1" | bc)
            echo "   ✅ $DISPLAY_NAME started (PID: $PID)"
            return 0
        fi
        sleep 0.1
    done

    echo "   ❌ $DISPLAY_NAME failed to start"
    exit 1
}

deploy_test_system() {
    echo "   Stopping existing test system..."
    if pgrep -f "node scripts/test-system.js" > /dev/null; then
        pkill -f "node scripts/test-system.js"
        echo "   ✅ Stopped existing test system"
    else
        echo "   ○ No existing test system running"
    fi

    echo ""
    echo "   Starting test system..."
    (node scripts/test-system.js 2>&1 | sed "s/^/[TEST] /") &
    BACKGROUND_PIDS+=($!)
    echo "   ✅ Test system deployed"
}

trap 'echo ""; echo "💥 FATAL: Deployment failed at line $LINENO"; echo "Command: $BASH_COMMAND"; echo "Exit code: $?"; echo ""; exit 1' ERR

export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STEP 1: DEVICE DISCOVERY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ "$DEVICE_TYPE" = "iphone" ]; then
    DEVICECTL_ID=$(xcrun devicectl list devices | grep "iPhone 17" | awk '{print $3}')
    DEVICE_NAME="iPhone 17 Pro Max"
    DEVICE_FAMILY=1
elif [ "$DEVICE_TYPE" = "ipad" ]; then
    DEVICECTL_ID=$(xcrun devicectl list devices | grep "iPad" | grep -v "Simulator" | head -1 | awk '{print $NF}')
    DEVICE_NAME="iPad"
    DEVICE_FAMILY=2
else
    echo "❌ Invalid device type: $DEVICE_TYPE"
    echo "   Valid options: iphone, ipad"
    exit 1
fi

if [ -z "$DEVICECTL_ID" ]; then
    echo "❌ FATAL: $DEVICE_NAME not found"
    echo "   Please connect device and try again"
    exit 1
fi

echo "   ✅ Found: $DEVICE_NAME"
echo "   Device ID: $DEVICECTL_ID"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STEP 2: BUILD IOS APPLICATION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "   Building application for $DEVICE_NAME..."
echo ""

# Create temporary file for build output
BUILD_LOG=$(mktemp)

/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild clean -project RealtimeClaude.xcodeproj -scheme RealtimeClaude -destination "generic/platform=iOS" TARGETED_DEVICE_FAMILY=$DEVICE_FAMILY > /dev/null 2>&1

# Redirect build output to temporary file
if /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project RealtimeClaude.xcodeproj -scheme RealtimeClaude -destination "generic/platform=iOS" -allowProvisioningUpdates -allowProvisioningDeviceRegistration CODE_SIGN_IDENTITY="Apple Development" CODE_SIGNING_REQUIRED=YES TARGETED_DEVICE_FAMILY=$DEVICE_FAMILY > "$BUILD_LOG" 2>&1; then
    # Build succeeded - print one-liner
    echo "   ✅ Build successful"
    rm "$BUILD_LOG"
else
    # Build failed - print full output
    echo "   ❌ Build failed - showing full output:"
    echo ""
    cat "$BUILD_LOG"
    rm "$BUILD_LOG"
    exit 1
fi

APP_PATH="/Users/felixlunzenfichter/Library/Developer/Xcode/DerivedData/RealtimeClaude-bbutrzksxnlhcedrvawihvkjxxkh/Build/Products/Debug-iphoneos/RealtimeClaude.app"
if [ ! -d "$APP_PATH" ]; then
    APP_PATH=$(find /Users/felixlunzenfichter/Library/Developer/Xcode/DerivedData -name "RealtimeClaude.app" -path "*/Debug-iphoneos/*" 2>/dev/null | head -1)
    if [ -z "$APP_PATH" ]; then
        echo "   ❌ Build artifact not found"
        exit 1
    fi
fi

echo "   Binary: $APP_PATH"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STEP 3: DEPLOY TEST SYSTEM"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

deploy_test_system

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STEP 4: DEPLOY COMPONENTS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "   Deploying Mac server..."
./scripts/deploy-mac-server.sh
echo "   ✅ Mac server deployed"

echo ""

echo "   Deploying iOS app..."
./scripts/deploy-iphone-app.sh
echo "   ✅ iOS app deployed"

echo ""

# Check for recent log activity (not older than 3 seconds)
echo "   Checking for recent log activity..."
LOG_DIR="$SCRIPT_DIR/private/logs"

# Ensure log directory exists
if [ ! -d "$LOG_DIR" ]; then
    echo "   ❌ FATAL: Log directory does not exist: $LOG_DIR"
    echo "   Reason: The private/logs directory must exist before deployment"
    exit 1
fi

check_logs() {
    for i in {1..100}; do
        LATEST_LOG=$(ls -t "$LOG_DIR"/*.json 2>/dev/null | head -1 || true)
        if [ -n "$LATEST_LOG" ]; then
            CURRENT_TIME=$(date +%s)
            LOG_MOD_TIME=$(stat -f %m "$LATEST_LOG" 2>/dev/null || echo 0)
            TIME_DIFF=$((CURRENT_TIME - LOG_MOD_TIME))
            if [ "$TIME_DIFF" -le 3 ]; then
                return 0
            fi
        fi
        sleep 0.1
    done
    return 1
}

# Check logs
if check_logs; then
    echo "   ✅ Recent log activity detected (${TIME_DIFF}s ago)"
    echo "   ✅ iPhone is connected and Mac server is running"
    SERVER_PID=$(pgrep -f "node scripts/mac-server.js")
    echo "   ○ Mac server active (PID: $SERVER_PID)"
else
    echo "   ❌ FATAL: Failed to establish connection or failed to find successful logs"
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "DEPLOYMENT COMPLETE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "   Test System: Running"
echo "   Mac Server: Running (PID: $SERVER_PID)"
echo "   Device: $DEVICE_NAME ($DEVICECTL_ID)"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "RUNNING - Press Ctrl+C to stop all processes"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Wait indefinitely for background processes
# This keeps the script alive so trap can catch SIGINT (Ctrl+C)
wait
