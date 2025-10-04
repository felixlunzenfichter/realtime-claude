#!/bin/bash

# Dogfooding: Exit immediately on any error
set -euo pipefail

# Add Homebrew to PATH for Apple Silicon Macs
if [[ -f /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Set Xcode developer directory for xcrun commands
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

echo "📂 Working directory: $(pwd)"

# Detect working directory
if [[ "$(pwd)" == *"RealtimeClaude.xcodeproj" ]]; then
    echo "📱 Detected Xcode project context"
    # Go up one directory to the main project folder
    cd ..
fi

SCRIPT_DIR="$(pwd)"
echo "📂 Project directory: $SCRIPT_DIR"

# Detect iPad device ID
echo "🔍 Detecting connected iPad device..."
IPAD_ID=$(xcrun xctrace list devices 2>&1 | grep -i "ipad" | grep -v "Simulator" | head -1 | sed 's/.*(\(.*\))/\1/' | grep -v "^$")
if [ -z "$IPAD_ID" ]; then
    echo "❌ No iPad found. Please connect your iPad and try again."
    exit 1
fi
echo "✅ Found device: iPad"
echo "   Device ID: $IPAD_ID"

# Build the app
echo "🔨 Building RealtimeClaude app for iPad..."

# Force iPad idiom for the build
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild clean -project RealtimeClaude.xcodeproj -scheme RealtimeClaude -destination "platform=iOS,id=$IPAD_ID" TARGETED_DEVICE_FAMILY=2
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project RealtimeClaude.xcodeproj -scheme RealtimeClaude -destination "platform=iOS,id=$IPAD_ID" -allowProvisioningUpdates -allowProvisioningDeviceRegistration "CODE_SIGN_IDENTITY=Apple Development" CODE_SIGNING_REQUIRED=YES TARGETED_DEVICE_FAMILY=2

# Find the built .app in DerivedData
APP_PATH="/Users/felixlunzenfichter/Library/Developer/Xcode/DerivedData/RealtimeClaude-bbutrzksxnlhcedrvawihvkjxxkh/Build/Products/Debug-iphoneos/RealtimeClaude.app"
if [ ! -d "$APP_PATH" ]; then
    echo "❌ Could not find RealtimeClaude.app at expected path"
    # Try to find it dynamically
    APP_PATH=$(find /Users/felixlunzenfichter/Library/Developer/Xcode/DerivedData -name "RealtimeClaude.app" -path "*/Debug-iphoneos/*" 2>/dev/null | head -1)
    if [ -z "$APP_PATH" ]; then
        echo "❌ Could not find RealtimeClaude.app anywhere"
        exit 1
    fi
fi

echo "✅ Build successful: $APP_PATH"

# Only clean up if we're also starting servers
if [ "${1:-}" = "--with-servers" ]; then
    echo "🧹 Cleaning up processes..."
    pkill -f "node test-system.js" 2>/dev/null || true
    pkill -f "node mac-server.js" 2>/dev/null || true
    lsof -ti:8082 | xargs kill -9 2>/dev/null || true
    sleep 1

    # Verify dependencies
    echo "🔍 Checking dependencies..."
    if ! command -v node &> /dev/null; then
        echo "❌ FATAL: Node.js is not installed! Run: brew install node"
        exit 1
    fi
    echo "✅ Node.js: $(node --version)"
    echo "✅ npm: $(npm --version)"

    # Check for chokidar
    echo "🔍 Checking for chokidar module..."
    if [ ! -d "node_modules/chokidar" ]; then
        echo "❌ chokidar is not installed. Installing..."
        npm install chokidar
    else
        echo "✅ chokidar module is installed"
    fi

    # Start test system
    echo "🚀 Starting Test system..."
    {
        node test-system.js 2>&1 | while IFS= read -r line; do
            echo "test: $line"
        done
    } &
    TEST_PID=$!

    # Wait for test system
    echo "⏳ Waiting for Test system to start..."
    MAX_WAIT=30
    WAIT_COUNT=0
    while ! pgrep -f "node test-system.js" > /dev/null; do
        sleep 0.1
        WAIT_COUNT=$((WAIT_COUNT + 1))
        if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
            echo "❌ Test system failed to start"
            exit 1
        fi
    done
    TEST_PID=$(pgrep -f "node test-system.js" | head -1)
    echo "✅ Test system started in ~.${WAIT_COUNT}s (PID: $TEST_PID)"

    # Start Mac server
    echo "🚀 Starting Mac server..."
    {
        node mac-server.js 2>&1 | while IFS= read -r line; do
            echo "server: $line"
        done
    } &
    SERVER_PID=$!

    # Wait for Mac server
    echo "⏳ Waiting for Mac server to start..."
    WAIT_COUNT=0
    while ! pgrep -f "node mac-server.js" > /dev/null; do
        sleep 0.1
        WAIT_COUNT=$((WAIT_COUNT + 1))
        if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
            echo "❌ Mac server failed to start"
            kill $TEST_PID 2>/dev/null || true
            exit 1
        fi
    done
    SERVER_PID=$(pgrep -f "node mac-server.js" | head -1)
    echo "✅ Mac server started in ~.${WAIT_COUNT}s (PID: $SERVER_PID)"

    echo "✅ Test system (PID: $TEST_PID) and Mac server (PID: $SERVER_PID) are running"
fi

# Install the app using xcrun devicectl
echo "📦 Installing app on iPad..."
xcrun devicectl device install app --device "$IPAD_ID" "$APP_PATH"

# Launch the app
echo "🚀 Launching app..."
xcrun devicectl device process launch --device "$IPAD_ID" ch.felix.realtimeClaude

echo "✅ App deployed and launched successfully!"
