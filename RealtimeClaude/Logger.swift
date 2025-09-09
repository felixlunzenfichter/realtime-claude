import Foundation
import SwiftUI
import Observation

enum LogType {
    case log
    case error
    
    var color: Color {
        switch self {
        case .log:
            return .primary
        case .error:
            return .red
        }
    }
    
    var label: String {
        switch self {
        case .log:
            return "LOG"
        case .error:
            return "ERROR"
        }
    }
}

struct LogMessage: Identifiable {
    let id = UUID()
    let type: LogType
    let timestamp: Date
    let fileName: String
    let functionName: String
    let message: String
    
    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter.string(from: timestamp)
    }
    
    var shortFileName: String {
        URL(fileURLWithPath: fileName).lastPathComponent
    }
}

@Observable
class Logger {
    private nonisolated(unsafe) static let shared = Logger()
    private var _logs: [LogMessage] = []
    
    private init() {
        let logMessage = LogMessage(
            type: .log,
            timestamp: Date(),
            fileName: #file,
            functionName: #function,
            message: "Logger initialized"
        )
        _logs.append(logMessage)
    }
    
    static var logs: [LogMessage] {
        return shared._logs
    }
    
    static func log(
        _ message: String,
        file: String = #file,
        function: String = #function
    ) {
        let logMessage = LogMessage(
            type: .log,
            timestamp: Date(),
            fileName: file,
            functionName: function,
            message: message
        )
        
        Logger.shared._logs.insert(logMessage, at: 0)
    }
    
    static func error(
        _ message: String,
        file: String = #file,
        function: String = #function
    ) {
        let logMessage = LogMessage(
            type: .error,
            timestamp: Date(),
            fileName: file,
            functionName: function,
            message: message
        )
        
        Logger.shared._logs.insert(logMessage, at: 0)
    }
}