#!/bin/bash

# Switch to deploy window (NOT claude window) and execute deployment

osascript <<'EOF'
    tell application "Terminal"
        set deployWindow to missing value

        -- Find a window with "deploy" in name but NOT "claude"
        repeat with w in windows
            set winName to name of w
            if winName contains "deploy" and winName does not contain "claude" and winName does not contain "Claude" then
                set deployWindow to w
                exit repeat
            end if
        end repeat

        -- If no deploy window found, try to find any window without "claude" in name
        if deployWindow is missing value then
            repeat with w in windows
                set winName to name of w
                if winName does not contain "claude" and winName does not contain "Claude" then
                    set deployWindow to w
                    exit repeat
                end if
            end repeat
        end if

        -- Only proceed if we found a valid window
        if deployWindow is not missing value then
            activate
            set index of deployWindow to 1

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
        else
            display dialog "No deploy terminal window found. Please open a Terminal window for deployment." buttons {"OK"} default button "OK"
        end if
    end tell
EOF
