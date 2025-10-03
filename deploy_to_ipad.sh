#!/bin/bash

# Complete test, server, and iOS deployment script
# Dogfooding: Exit immediately on any error
set -euo pipefail

# Crash handler - log any script errors
trap 'echo "💥 FATAL: Deployment script crashed at line $LINENO!"; echo "❌ This is unacceptable - fix the error!"; exit 1' ERR

# Add Homebrew to PATH for Apple Silicon Macs
if [[ -f /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Set Xcode developer directory for xcrun commands
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

echo "🚀 Starting Logging System Test & Deploy Sequence..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Step 1: Clean up any existing processes
echo "🧹 Cleaning up existing processes..."
pkill -f "node test-system.js" 2>/dev/null || true
pkill -f "node mac-server.js" 2>/dev/null || true

# Clean up port 8082 if it's in use
echo "🔧 Cleaning up port 8082..."
lsof -ti:8082 | xargs kill -9 2>/dev/null || true
sleep 2


# Step 3: Verify required dependencies
echo "🔍 Checking dependencies..."
if ! command -v node &> /dev/null; then
    echo "❌ FATAL: Node.js is not installed! Run: brew install node"
    exit 1
fi
echo "✅ Node.js: $(node --version)"
echo "✅ npm: $(npm --version)"

# Step 4: Start the test system in background
echo "🧪 Starting logging system test..."
node test-system.js &
TEST_PID=$!
sleep 2

# Step 5: Start the Mac server in background
echo "🖥️ Starting Mac server..."
node mac-server.js &
SERVER_PID=$!
sleep 3

echo "✅ Test system (PID: $TEST_PID) and Mac server (PID: $SERVER_PID) are running"

# Step 6: Detect iPad device ID
echo "🔍 Detecting connected iPad device..."
# Get full device info and extract the device ID
IPAD_INFO=$(xcrun xctrace list devices 2>&1 | grep -i "ipad" | grep -v "Simulator" | head -1)
IPAD_ID=$(echo "$IPAD_INFO" | sed 's/.*(\(.*\))/\1/')
IPAD_NAME=$(echo "$IPAD_INFO" | sed 's/ (.*//')

if [ -z "$IPAD_ID" ]; then
    # Fallback to ios-deploy if xctrace doesn't work
    IPAD_ID=$(ios-deploy --detect --timeout 2 2>/dev/null | grep -i "ipad" | head -1 | awk '{print $1}')
    if [ -n "$IPAD_ID" ]; then
        IPAD_NAME="iPad"
    fi
fi

if [ -z "$IPAD_ID" ]; then
    echo "❌ No iPad device found. Please connect an iPad and try again."
    [ -n "$TEST_PID" ] && kill $TEST_PID 2>/dev/null || true
    [ -n "$SERVER_PID" ] && kill $SERVER_PID 2>/dev/null || true
    exit 1
fi

echo "✅ Found device: $IPAD_NAME"
echo "   Device ID: $IPAD_ID"

# Step 7: Deploy and launch iOS app
echo "🔨 Building RealtimeClaude app for iPad..."

# Clean and build (using detected iPad device ID with automatic signing)
# You may need to add your DEVELOPMENT_TEAM ID here if automatic signing fails
# Find your team ID in Xcode: Preferences > Accounts > View Details
# Then uncomment and update the line below:
# DEVELOPMENT_TEAM="YOUR_TEAM_ID"

if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
    TEAM_ARGS="DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
else
    TEAM_ARGS=""
fi

/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild clean -project RealtimeClaude.xcodeproj -scheme RealtimeClaude -destination "platform=iOS,id=$IPAD_ID"
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project RealtimeClaude.xcodeproj -scheme RealtimeClaude -destination "platform=iOS,id=$IPAD_ID" -allowProvisioningUpdates -allowProvisioningDeviceRegistration CODE_SIGN_IDENTITY="Apple Development" CODE_SIGNING_REQUIRED=YES $TEAM_ARGS

# Find the built .app in DerivedData
APP_PATH="/Users/felixlunzenfichter/Library/Developer/Xcode/DerivedData/RealtimeClaude-bbutrzksxnlhcedrvawihvkjxxkh/Build/Products/Debug-iphoneos/RealtimeClaude.app"
if [ ! -d "$APP_PATH" ]; then
    echo "❌ Could not find RealtimeClaude.app at expected path"
    # Try to find it dynamically
    APP_PATH=$(find /Users/felixlunzenfichter/Library/Developer/Xcode/DerivedData -name "RealtimeClaude.app" -path "*/Debug-iphoneos/*" 2>/dev/null | head -1)
    if [ -z "$APP_PATH" ]; then
        echo "❌ Could not find RealtimeClaude.app anywhere"
        kill $TEST_PID $SERVER_PID 2>/dev/null || true
        exit 1
    fi
fi

echo "📱 Installing and launching app from: $APP_PATH"

# Install the app using xcrun devicectl (modern replacement for ios-deploy)
echo "📦 Installing app on iPad..."
xcrun devicectl device install app --device "$IPAD_ID" "$APP_PATH"

# Launch the app
echo "🚀 Launching app..."
xcrun devicectl device process launch --device "$IPAD_ID" ch.felix.realtimeClaude

echo "✅ App deployed and launched successfully!"
echo "🔍 Monitoring test results..."
echo "📊 Test system PID: $TEST_PID"
echo "🖥️ Server PID: $SERVER_PID"
echo ""
echo "💡 Test Requirements:"
echo "    ✓ Test 1: 'Successful handshake' message"
echo "    ✓ Test 2: No error logs allowed"
echo ""
echo "💡 Test will continue monitoring even after passing to catch late errors"
echo "💡 You can manually check logs with: tail -f private/ios-logs.json"
echo "💡 To stop monitoring: Press Ctrl+C or kill $TEST_PID $SERVER_PID"

# Wait for test to complete or user to interrupt
# The test will keep running to monitor for errors
wait $TEST_PID
