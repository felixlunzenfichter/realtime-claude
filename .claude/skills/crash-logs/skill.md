---
name: crash-logs
description: Find and analyze the latest crash log from connected iPhone for RealtimeClaude. Use when the app crashes and you need to understand what went wrong.
allowed-tools:
  - Bash
  - Read
---

# Crash Logs Skill

Finds and analyzes the latest crash log for RealtimeClaude from a connected iPhone using `idevicecrashreport`.

## How This Skill Works

This skill:
1. Uses `idevicecrashreport` (from libimobiledevice) to pull crash logs from the connected iPhone
2. Filters for RealtimeClaude crashes specifically
3. Parses the latest .ips file (JSON format) to extract key crash information
4. Returns a summary with exception type, ASI message, and crashed function

## Prerequisites

Install libimobiledevice if not already installed:

```bash
brew install libimobiledevice
```

## Implementation

### Step 1: Extract Crash Logs from Device

```bash
idevicecrashreport -e -k -f RealtimeClaude /tmp/crash_logs
```

Flags:
- `-e` = extract crash reports from device
- `-k` = keep (don't delete from device)
- `-f RealtimeClaude` = filter by app name

Run with `run_in_background: true`

### Step 2: Find Latest .ips File

```bash
ls -t /tmp/crash_logs/RealtimeClaude*.ips | head -1
```

This lists .ips files sorted by modification time and returns the most recent.

Run with `run_in_background: true`

### Step 3: Read and Parse the .ips File

Read the .ips file using the Read tool. It's JSON format. Key fields to extract:

**Primary crash information (typically around line 49-53):**
- Line 49: `"exception"` - contains `type` (EXC_BREAKPOINT, EXC_BAD_ACCESS, etc.) and `signal`
- Line 52: `"asi"` - **Application Specific Information** - Contains the REAL error message like "API MISUSE: Resurrection of an object which should have been deallocated"
- Line 53: `"faultingThread"` - which thread number crashed

**Thread details:**
- Find the `"threads"` array
- Look for the thread with `"triggered":true` - this is the crashed thread
- Extract the `"frames"` array from that thread
- Look for frames containing "RealtimeClaude" in the `imageIdentifier` or `symbol` fields

### Step 4: Return Summary

Provide:
- **Crash Time**: Extract from `"captureTime"` field (typically line 3)
- **Exception Type**: From `exception.type` and `exception.signal`
- **ASI Message**: From `asi` field - **THIS IS THE REAL REASON** for most crashes
- **Crashed Thread**: Thread number from `faultingThread`
- **Crashed Function**: Extract the topmost RealtimeClaude frame from the triggered thread
- **File/Line**: If available in the frame's `symbol` field
- **Analysis**: Brief interpretation based on the ASI message and exception type

## Key Insights

### ASI (Application Specific Information) is Critical

The `asi` field contains high-level error descriptions like:
- "API MISUSE: Resurrection of an object which should have been deallocated"
- "API MISUSE: -[AVCaptureSession startRunning] should only be called from background thread"
- Fatal errors and assertion messages

This is typically MORE useful than the raw exception type.

### Common Exception Types

- `EXC_BREAKPOINT` (SIGTRAP) - Usually triggered by Swift runtime checks, fatalError(), precondition failures
- `EXC_BAD_ACCESS` (SIGSEGV/SIGBUS) - Memory access violations, accessing deallocated objects
- `EXC_CRASH` (SIGABRT) - Assertions, forced aborts
- `EXC_BAD_INSTRUCTION` (SIGILL) - Usually force unwrapping nil optionals

### Finding the Crashed Function

1. Find the thread with `"triggered":true`
2. Look at frames (index 0 is topmost/most recent)
3. Skip system frameworks (AudioToolbox, AVFAudio, etc.)
4. Find the first frame with "RealtimeClaude" in `imageIdentifier`
5. Extract the `symbol` field - this is the crashed function

## Example Output

```
Crash Analysis for RealtimeClaude

Crash Time: 2025-12-10 15:23:45
Exception Type: EXC_BREAKPOINT (SIGTRAP)
ASI Message: API MISUSE: Resurrection of an object which should have been deallocated - RealtimeClaude.AudioManager instance

Crashed Thread: 7
Crashed Function: RealtimeClaude.AudioManager.handleAudioBuffer()
File: AudioManager.swift:245

Analysis: AVAudioEngine attempted to call a callback on an AudioManager instance that was already deallocated. This is a lifetime management issue - the AudioManager was released while the audio engine still had a reference to it.
```

## Notes

- Always use `run_in_background: true` for all bash commands
- The .ips files are JSON, making them easy to parse
- Focus on the ASI message first - it usually contains the most actionable information
- If no crash logs found, check that:
  - Device is connected and trusted
  - Device is unlocked
  - libimobiledevice is installed
- Crash logs are pulled directly from device, no need to wait for sync
