#!/bin/bash

APPROVAL_FILE="/tmp/.merge-approval"
TIMEOUT=120

echo ""
echo "⏳ Waiting for iOS approval..."
echo "   Tap [Merge ✓] button in the app"
echo ""

for i in $(seq 1 $TIMEOUT); do
    if [ -f "$APPROVAL_FILE" ]; then
        TOKEN_AGE=$(( $(date +%s) - $(stat -f %m "$APPROVAL_FILE") ))
        if [ $TOKEN_AGE -lt 30 ]; then
            rm -f "$APPROVAL_FILE"
            echo "✅ Approved by iOS!"
            echo ""
            exit 0
        else
            echo "❌ Approval token expired (${TOKEN_AGE}s old)"
            rm -f "$APPROVAL_FILE"
        fi
    fi

    if [ $((i % 10)) -eq 0 ]; then
        echo "   Still waiting... (${i}s)"
    fi

    sleep 1
done

echo ""
echo "❌ Approval timeout (${TIMEOUT}s)"
echo "   No button tap received from iOS"
echo ""
exit 1
