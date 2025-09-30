import Foundation

extension Int {
    var formattedBytes: String {
        switch self {
        case 0..<1000:
            return "\(self) B"
        case 1000..<1000000:
            let kb = Double(self) / 1000.0
            if kb < 10 {
                return String(format: "%.2f KB", kb)
            } else if kb < 100 {
                return String(format: "%.1f KB", kb)
            } else {
                return String(format: "%.0f KB", kb)
            }
        case 1000000..<1000000000:
            let mb = Double(self) / 1000000.0
            if mb < 10 {
                return String(format: "%.2f MB", mb)
            } else if mb < 100 {
                return String(format: "%.1f MB", mb)
            } else {
                return String(format: "%.0f MB", mb)
            }
        default:
            let gb = Double(self) / 1000000000.0
            if gb < 10 {
                return String(format: "%.2f GB", gb)
            } else if gb < 100 {
                return String(format: "%.1f GB", gb)
            } else {
                return String(format: "%.0f GB", gb)
            }
        }
    }

    var formattedDuration: String {
        let hours = self / 3600
        let minutes = (self % 3600) / 60
        let seconds = self % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    var formattedHumanDuration: String {
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
}

extension Int {
    var formattedSeconds: String {
        formattedHumanDuration
    }

    var formattedMilliseconds: String {
        let seconds = self / 1000
        return seconds.formattedHumanDuration
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
