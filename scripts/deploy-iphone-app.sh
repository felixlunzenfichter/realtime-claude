#!/bin/bash

set -euo pipefail

trap 'echo ""; echo "💥 FATAL: iPhone app deployment failed at line $LINENO"; echo "Command: $BASH_COMMAND"; echo "Exit code: $?"; echo ""; exit 1' ERR

export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "DEPLOY IPHONE APP"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Device discovery
echo "📱 Discovering device..."

DEVICECTL_ID=$(xcrun devicectl list devices | grep "iPhone 17" | awk '{print $3}')
DEVICE_NAME="iPhone 17 Pro Max"

if [ -z "$DEVICECTL_ID" ]; then
    echo "❌ No iPhone device found. Please connect an iPhone and try again."
    exit 1
fi

echo "✅ Found device: $DEVICE_NAME (ID: $DEVICECTL_ID)"
echo ""

# Find existing app binary (already built in main deploy.sh)
echo "📦 Using existing build artifact..."
APP_PATH="/Users/felixlunzenfichter/Library/Developer/Xcode/DerivedData/RealtimeClaude-bbutrzksxnlhcedrvawihvkjxxkh/Build/Products/Debug-iphoneos/RealtimeClaude.app"
if [ ! -d "$APP_PATH" ]; then
    APP_PATH=$(find /Users/felixlunzenfichter/Library/Developer/Xcode/DerivedData -name "RealtimeClaude.app" -path "*/Debug-iphoneos/*" 2>/dev/null | head -1)
    if [ -z "$APP_PATH" ]; then
        echo "❌ Could not find RealtimeClaude.app anywhere"
        exit 1
    fi
fi

echo "✅ Binary: $APP_PATH"
echo ""

# Install app
echo "📦 Installing app on $DEVICE_NAME..."
xcrun devicectl device install app --device "$DEVICECTL_ID" "$APP_PATH"
echo "✅ App installed"
echo ""

# Launch app
echo "🚀 Launching app..."
xcrun devicectl device process launch --device "$DEVICECTL_ID" ch.felix.realtimeClaude
echo "✅ App launched"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ iPhone app deployed and launched successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
