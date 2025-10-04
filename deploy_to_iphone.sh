#!/bin/bash

set -euo pipefail

cleanup_processes() {
    echo "🧹 Cleaning up processes..."

    if pgrep -f "node test-system.js" > /dev/null; then
        echo "   Stopping test-system.js..."
        pkill -f "node test-system.js"
    fi

    if pgrep -f "node mac-server.js" > /dev/null; then
        echo "   Stopping mac-server.js..."
        pkill -f "node mac-server.js"
    fi

    if lsof -ti:8082 > /dev/null 2>&1; then
        echo "   Cleaning up port 8082..."
        lsof -ti:8082 | xargs kill -9
    fi

    echo "✅ Cleanup complete"
}

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

trap 'echo "💥 FATAL: Deployment script crashed at line $LINENO!"; cleanup_processes; exit 1' ERR

export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "📂 Working directory: $SCRIPT_DIR"

DEVICE_INFO=$(xcodebuild -showdestinations -scheme RealtimeClaude 2>&1 | grep "platform:iOS" | grep -i "iphone" | grep -v "Simulator" | grep -v "Any iOS" | head -1)
DEVICE_ID=$(echo "$DEVICE_INFO" | sed 's/.*id:\([^,]*\).*/\1/')
DEVICE_NAME=$(echo "$DEVICE_INFO" | sed 's/.*name:\([^}]*\).*/\1/' | sed 's/ *$//')

if [ -z "$DEVICE_ID" ]; then
    echo "❌ No iPhone device found. Please connect an iPhone and try again."
    exit 1
fi

echo "✅ Found device: $DEVICE_NAME (ID: $DEVICE_ID)"

echo "🔨 Building RealtimeClaude app for iPhone..."

/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild clean -project RealtimeClaude.xcodeproj -scheme RealtimeClaude -destination "platform=iOS,id=$DEVICE_ID" TARGETED_DEVICE_FAMILY=1

/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project RealtimeClaude.xcodeproj -scheme RealtimeClaude -destination "platform=iOS,id=$DEVICE_ID" -allowProvisioningUpdates -allowProvisioningDeviceRegistration CODE_SIGN_IDENTITY="Apple Development" CODE_SIGNING_REQUIRED=YES TARGETED_DEVICE_FAMILY=1

APP_PATH="/Users/felixlunzenfichter/Library/Developer/Xcode/DerivedData/RealtimeClaude-bbutrzksxnlhcedrvawihvkjxxkh/Build/Products/Debug-iphoneos/RealtimeClaude.app"
if [ ! -d "$APP_PATH" ]; then
    APP_PATH=$(find /Users/felixlunzenfichter/Library/Developer/Xcode/DerivedData -name "RealtimeClaude.app" -path "*/Debug-iphoneos/*" 2>/dev/null | head -1)
    if [ -z "$APP_PATH" ]; then
        echo "❌ Could not find RealtimeClaude.app anywhere"
        exit 1
    fi
fi

echo "✅ Build successful: $APP_PATH"

cleanup_processes

echo "🔍 Checking dependencies..."

if ! command -v node &> /dev/null; then
    echo "❌ FATAL: Node.js is not installed!"
    exit 1
fi

echo "✅ Node.js: $(node --version)"
echo "✅ npm: $(npm --version)"

npm list chokidar &>/dev/null || { echo "❌ FATAL: chokidar not installed! Run: npm install"; exit 1; }

echo "✅ chokidar module is installed"

start_node_process "test-system.js" "Test system" "TEST"
TEST_PID=$!

start_node_process "mac-server.js" "Mac server" "SERVER"
SERVER_PID=$!

echo "✅ Test system (PID: $TEST_PID) and Mac server (PID: $SERVER_PID) are running"
echo "📦 Installing app on iPhone..."

xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

echo "🚀 Launching app..."

xcrun devicectl device process launch --device "$DEVICE_ID" ch.felix.realtimeClaude

echo "✅ App deployed and launched successfully!"

wait $TEST_PID