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

# Check for chokidar module
echo "🔍 Checking for chokidar module..."
if ! npm list chokidar >/dev/null 2>&1; then
    echo "❌ FATAL: chokidar module is not installed!"
    echo ""
    echo "📦 To fix this, run:"
    echo "   npm install"
    echo ""
    echo "This will install all dependencies including chokidar."
    exit 1
fi
echo "✅ chokidar module is installed"

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

# Step 6: Detect iPhone device ID
echo "🔍 Detecting connected iPhone device..."
# Use xcodebuild to find available iPhone devices
DEVICE_INFO=$(xcodebuild -showdestinations -scheme RealtimeClaude 2>&1 | grep "platform:iOS" | grep -i "iphone" | grep -v "Simulator" | grep -v "Any iOS" | head -1)
DEVICE_ID=$(echo "$DEVICE_INFO" | sed 's/.*id:\([^,]*\).*/\1/')
DEVICE_NAME=$(echo "$DEVICE_INFO" | sed 's/.*name:\([^}]*\).*/\1/' | sed 's/ *$//')

if [ -z "$DEVICE_ID" ]; then
    echo "❌ No iPhone device found. Please connect an iPhone and try again."
    [ -n "$TEST_PID" ] && kill $TEST_PID 2>/dev/null || true
    [ -n "$SERVER_PID" ] && kill $SERVER_PID 2>/dev/null || true
    exit 1
fi

echo "✅ Found device: $DEVICE_NAME"
echo "   Device ID: $DEVICE_ID"

# Step 7: Deploy and launch iOS app
echo "🔨 Building RealtimeClaude app for iPhone..."

# Clean and build (using detected iPhone device ID with automatic signing)
# You may need to add your DEVELOPMENT_TEAM ID here if automatic signing fails
# Find your team ID in Xcode: Preferences > Accounts > View Details
# Then uncomment and update the line below:
# DEVELOPMENT_TEAM="YOUR_TEAM_ID"

if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
    TEAM_ARGS="DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
else
    TEAM_ARGS=""
fi

/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild clean -project RealtimeClaude.xcodeproj -scheme RealtimeClaude -destination "platform=iOS,id=$DEVICE_ID" TARGETED_DEVICE_FAMILY=1
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project RealtimeClaude.xcodeproj -scheme RealtimeClaude -destination "platform=iOS,id=$DEVICE_ID" -allowProvisioningUpdates -allowProvisioningDeviceRegistration CODE_SIGN_IDENTITY="Apple Development" CODE_SIGNING_REQUIRED=YES TARGETED_DEVICE_FAMILY=1 $TEAM_ARGS

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
echo "📦 Installing app on iPhone..."
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

# Launch the app
echo "🚀 Launching app..."
xcrun devicectl device process launch --device "$DEVICE_ID" ch.felix.realtimeClaude

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
