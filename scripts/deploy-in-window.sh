#!/bin/bash

# Switch to scripts window and execute deployment

osascript <<'EOF'
    tell application "Terminal"
        activate
        repeat with w from 1 to count of windows
            if name of window w contains "scripts" then
                set index of window w to 1
            end if
        end repeat
    end tell

    delay 0.3

    tell application "System Events"
        tell process "Terminal"
            keystroke "c" using control down
            delay 0.5
            keystroke "./deploy.sh"
            delay 0.2
            key code 36
        end tell
    end tell
EOF
