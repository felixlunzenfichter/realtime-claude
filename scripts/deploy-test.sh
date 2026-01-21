#!/bin/bash
set -e

echo "🧪 TEST DEPLOYMENT - Does not affect production"

# Check for manual flag
if [ "$1" = "--manual" ]; then
    echo "📋 Manual testing mode"
    echo "   - Real voice input"
    echo "   - TTS enabled"
    echo "   - No auto-execute"
    SWIFT_FLAGS='-DIS_TEST -DMANUAL_TESTING'
    SERVER_FLAGS='IS_TEST=true MANUAL_TESTING=true'
else
    echo "🤖 Automated testing mode"
    echo "   - Mock audio"
    echo "   - TTS disabled"
    echo "   - Auto-execute story"
    SWIFT_FLAGS='-DIS_TEST'
    SERVER_FLAGS='IS_TEST=true'
fi

# Kill only test server (port 9999), leave production (8082) alone
echo "Restarting test server on port 9999..."
lsof -ti :9999 | xargs kill -9 2>/dev/null || true
sleep 1
eval "$SERVER_FLAGS SERVER_PORT=9999 node scripts/mac-server.js > /tmp/mac-server-test.log 2>&1 &"
sleep 2

# Verify test server started
if ! lsof -i :9999 | grep LISTEN > /dev/null; then
    echo "❌ Test server failed to start"
    exit 1
fi
echo "✅ Test server running on 9999"

# Build with appropriate flags
echo "Building with flags: $SWIFT_FLAGS"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
IPHONE_ID=$(xcodebuild -scheme RealtimeClaude -showdestinations 2>/dev/null | grep "name:iPhone" | grep -o 'id:[^,]*' | head -1 | cut -d: -f2)

if [ -z "$IPHONE_ID" ]; then
    echo "❌ No iPhone found"
    exit 1
fi

xcodebuild -scheme RealtimeClaude -project RealtimeClaude.xcodeproj \
    -destination "id=$IPHONE_ID" \
    OTHER_SWIFT_FLAGS="$SWIFT_FLAGS" \
    -derivedDataPath /tmp/build-test \
    build

# Install and launch
echo "Installing on iPhone..."
xcrun devicectl device install app --device "$IPHONE_ID" /tmp/build-test/Build/Products/Debug-iphoneos/RealtimeClaude.app
xcrun devicectl device process launch --terminate-existing --device "$IPHONE_ID" ch.felix.realtimeClaude

echo "✅ TEST DEPLOYMENT COMPLETE"
echo "📊 Watch logs: tail -f /tmp/mac-server-test.log"

# Write test-passed marker with current commit hash
REPO_ROOT=$(git rev-parse --show-toplevel)
COMMIT_HASH=$(git rev-parse HEAD)

if [ "$1" = "--manual" ]; then
    echo ""
    echo "🎤 Manual test deployed. Speak and verify the app works."
    echo "   When verified, run: ./scripts/mark-manual-passed.sh"
else
    echo "$COMMIT_HASH" > "$REPO_ROOT/.test-passed-automated"
    echo "✅ Wrote .test-passed-automated ($COMMIT_HASH)"
fi

echo ""
