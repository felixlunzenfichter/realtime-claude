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
}