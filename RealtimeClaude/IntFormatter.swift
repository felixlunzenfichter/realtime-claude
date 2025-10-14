/*
# REFACTORING DOCUMENT: IntFormatter.swift

## Current State: ✅ PROPERLY ORDERED

### Extension: Int

#### Computed Properties:
Line 23: formattedBytes: String (public, get-only) → uses: self
Line 57: formattedDuration: String (public, get-only) → uses: self
Line 71: formattedSeconds: String (public, get-only) → uses: formattedDuration
Line 75: formattedMilliseconds: String (public, get-only) → uses: self, formattedDuration

### Extension: Date

#### Computed Properties:
Line 81: formattedTimestamp: String (public, get-only) → uses: self
*/

import Foundation

extension Int {
    var formattedBytes: String {
        let result: String
        switch self {
        case 0..<1000:
            result = "\(self) B"
        case 1000..<1000000:
            let kb = Double(self) / 1000.0
            if kb < 10 {
                result = String(format: "%.2f KB", kb)
            } else if kb < 100 {
                result = String(format: "%.1f KB", kb)
            } else {
                result = String(format: "%.0f KB", kb)
            }
        case 1000000..<1000000000:
            let mb = Double(self) / 1000000.0
            if mb < 10 {
                result = String(format: "%.2f MB", mb)
            } else if mb < 100 {
                result = String(format: "%.1f MB", mb)
            } else {
                result = String(format: "%.0f MB", mb)
            }
        default:
            let gb = Double(self) / 1000000000.0
            if gb < 10 {
                result = String(format: "%.2f GB", gb)
            } else if gb < 100 {
                result = String(format: "%.1f GB", gb)
            } else {
                result = String(format: "%.0f GB", gb)
            }
        }
        return String(format: "%8s", (result as NSString).utf8String!)
    }

    var formattedDuration: String {
        let hours = self / 3600
        let minutes = (self % 3600) / 60
        let seconds = self % 60

        if hours > 0 {
            return String(format: "%dh %dm %ds", hours, minutes, seconds)
        } else if minutes > 0 {
            return String(format: "%dm %ds", minutes, seconds)
        } else {
            return String(format: "%ds", seconds)
        }
    }

    var formattedSeconds: String {
        formattedDuration
    }

    var formattedMilliseconds: String {
        (self / 1000).formattedDuration
    }
}

extension Date {
    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeStyle = .medium
        return formatter.string(from: self)
    }
}
