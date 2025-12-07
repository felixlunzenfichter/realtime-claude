#!/bin/bash

set -euo pipefail

# Clear previous log and redirect all output to /tmp/deploy.log
> /tmp/deploy.log
exec > >(tee -a /tmp/deploy.log) 2>&1

# Log deployment start time
echo "=== Deployment started at $(date '+%Y-%m-%d %H:%M:%S') ==="
echo ""

DEVICE_TYPE=${1:-iphone}

trap 'echo ""; echo "💥 FATAL: Deployment failed at line $LINENO"; echo "Command: $BASH_COMMAND"; echo "Exit code: $?"; echo ""; exit 1' ERR

export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

echo ""
echo "--------------------------------------------------------------------------------"
echo "STEP 1: DEPLOY MAC SERVER"
echo "--------------------------------------------------------------------------------"
echo ""

echo "🧹 Cleaning up existing Mac server processes..."
pkill -f "node scripts/mac-server.js" 2>/dev/null || true
lsof -ti:8082 | xargs kill -9 2>/dev/null || true
pkill -f "tail -f /tmp/mac-server-output.log" 2>/dev/null || true
sleep 0.5
echo "✅ Mac server cleanup complete"

echo "🚀 Starting Mac server..."
# Start server with explicitly closed FDs (0,1,2 redirected, 3-9 closed)
exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-
node scripts/mac-server.js > /tmp/mac-server-output.log 2>&1 &
SERVER_PID=$!

# Now start the tail|sed pipe (server already has clean FDs)
tail -f /tmp/mac-server-output.log | sed -l "s/^/[SERVER] /" &

for i in {1..100}; do
    if pgrep -f "node scripts/mac-server.js" > /dev/null; then
        ELAPSED=$(echo "scale=1; $i * 0.1" | bc)
        echo "✅ Mac server started in ~${ELAPSED}s"
        break
    fi
    sleep 0.1
done

echo ""
echo "--------------------------------------------------------------------------------"
echo "STEP 2: DEVICE DISCOVERY"
echo "--------------------------------------------------------------------------------"
echo ""

if [ "$DEVICE_TYPE" = "iphone" ]; then
    DEVICECTL_ID=$(xcrun devicectl list devices | grep "iPhone 17" | awk '{print $3}')
    DEVICE_NAME="iPhone 17 Pro Max"
    DEVICE_FAMILY=1
elif [ "$DEVICE_TYPE" = "ipad" ]; then
    DEVICECTL_ID=$(xcrun devicectl list devices | grep "iPad" | grep -v "Simulator" | head -1 | awk '{print $4}')
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
echo "--------------------------------------------------------------------------------"
echo "STEP 3: BUILD IOS APPLICATION"
echo "--------------------------------------------------------------------------------"
echo ""

echo "   Building application for $DEVICE_NAME..."
echo ""

# Create temporary file for build output
BUILD_LOG=$(mktemp)

# Try build without clean first (faster)
if /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project RealtimeClaude.xcodeproj -scheme RealtimeClaude -destination "generic/platform=iOS" TARGETED_DEVICE_FAMILY=$DEVICE_FAMILY DEVELOPMENT_TEAM=W26GVS4M5S CODE_SIGN_IDENTITY="Apple Development" > "$BUILD_LOG" 2>&1; then
    # Build succeeded
    echo "   ✅ Build successful"

    # Check for warnings even on success
    if grep -q "warning:" "$BUILD_LOG"; then
        echo ""
        echo "   ⚠️  Warnings:"
        grep "warning:" "$BUILD_LOG"
        echo ""
    fi

    rm "$BUILD_LOG"
else
    # Build failed - show errors and warnings
    echo "   ❌ Build failed - showing errors and warnings:"
    echo ""
    grep "error:" "$BUILD_LOG" || true
    grep "warning:" "$BUILD_LOG" || true
    echo ""

    # Try clean and rebuild
    echo "   ⚠️  Trying clean build..."
    echo ""

    /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild clean -project RealtimeClaude.xcodeproj -scheme RealtimeClaude -destination "generic/platform=iOS" TARGETED_DEVICE_FAMILY=$DEVICE_FAMILY > /dev/null 2>&1

    if /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project RealtimeClaude.xcodeproj -scheme RealtimeClaude -destination "generic/platform=iOS" TARGETED_DEVICE_FAMILY=$DEVICE_FAMILY DEVELOPMENT_TEAM=W26GVS4M5S CODE_SIGN_IDENTITY="Apple Development" > "$BUILD_LOG" 2>&1; then
        echo "   ✅ Clean build successful"

        # Check for warnings even on success
        if grep -q "warning:" "$BUILD_LOG"; then
            echo ""
            echo "   ⚠️  Warnings:"
            grep "warning:" "$BUILD_LOG"
            echo ""
        fi

        rm "$BUILD_LOG"
    else
        # Clean build also failed - print errors and exit
        echo "   ❌ Clean build also failed - showing errors and warnings:"
        echo ""
        grep "error:" "$BUILD_LOG" || true
        grep "warning:" "$BUILD_LOG" || true
        rm "$BUILD_LOG"
        exit 1
    fi
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
echo "--------------------------------------------------------------------------------"
echo "STEP 4: DEPLOY IOS APP"
echo "--------------------------------------------------------------------------------"
echo ""

echo "   Installing app on $DEVICE_NAME..."
xcrun devicectl device install app --device "$DEVICECTL_ID" "$APP_PATH"
echo "   ✅ App installed"

echo ""

echo "   Launching app..."
xcrun devicectl device process launch --device "$DEVICECTL_ID" ch.felix.realtimeClaude
echo "   ✅ App launched"

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
    SERVER_PID=$(pgrep -f "node scripts/mac-server.js" || true)
    echo "   ○ Mac server active (PID: $SERVER_PID)"
else
    echo "   ❌ FATAL: Failed to establish connection or failed to find successful logs"
    exit 1
fi

echo ""
echo "--------------------------------------------------------------------------------"
echo "DEPLOYMENT COMPLETE"
echo "--------------------------------------------------------------------------------"
echo ""
echo "   Mac Server: Running (PID: $SERVER_PID)"
echo "   Device: $DEVICE_NAME ($DEVICECTL_ID)"
echo ""
echo "--------------------------------------------------------------------------------"
echo "RUNNING - Press Ctrl+C to stop all processes"
echo "--------------------------------------------------------------------------------"
echo ""

# Wait indefinitely for background processes
# This keeps the script alive so trap can catch SIGINT (Ctrl+C)
wait
