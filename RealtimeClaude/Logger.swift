import Foundation
import SwiftUI
import Network
import Combine

enum LogType: Codable {
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
struct LogMessage: Identifiable, Codable, Sendable {
    var id = UUID()
    let type: LogType
    let timestamp: Date
    let fileName: String
    let functionName: String
    let message: String
    
    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter.string(from: timestamp)
    }
    
    var shortFileName: String {
        URL(fileURLWithPath: fileName).lastPathComponent
    }
}

class Logger: @unchecked Sendable {
    static let shared = Logger()
    
    private var _logs: [LogMessage] = []
    private var _transmittedLogIds: [String] = []
    private let connection: NWConnection
    private let macHostname = "Felixs-MacBook-Pro.local"
    private let port: UInt16 = 8082
    private var dataBuffer = Data()

    let logsSubject = CurrentValueSubject<[LogMessage], Never>([])
    let transmittedLogIdsSubject = CurrentValueSubject<[String], Never>([])
    let sessionNumberSubject = CurrentValueSubject<Int, Never>(0)
    let uptimeTodaySubject = CurrentValueSubject<Int, Never>(0)
    let uptimeTotalSubject = CurrentValueSubject<Int, Never>(0)
    let totalLogsSubject = CurrentValueSubject<Int, Never>(0)

    private var sessionNumber: Int = 0

    private init() {
        
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(macHostname), port: NWEndpoint.Port(rawValue: port)!)
        connection = NWConnection(to: endpoint, using: .tcp)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.startReceiving()
                self.sendStartMessage()
            case .failed(let error):
                fatalError("Logger connection failed: \(error)")
            default:
                break
            }
        }

        connection.start(queue: .global())
    }

    func addLog(
        _ message: String,
        type: LogType = .log,
        file: String = #file,
        function: String = #function
    ) {
        let logMessage = LogMessage(
            type: type,
            timestamp: Date(),
            fileName: file,
            functionName: function,
            message: message
        )

        addLogMessage(logMessage)
        sendLog(logMessage)
    }

    private func addLogMessage(_ logMessage: LogMessage) {
        _logs.insert(logMessage, at: 0)
        logsSubject.send(_logs)
    }

    private func sendLog(_ logMessage: LogMessage) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        var jsonData = try! encoder.encode(logMessage)

        jsonData.append("\n".data(using: .utf8)!)

        connection.send(content: jsonData, completion: .contentProcessed { error in
            if let error = error {
                fatalError("Failed to send log: \(error)")
            }
        })
    }

    private func startReceiving() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let error = error {
                fatalError("Logger receive failed: \(error)")
            }

            if let data = data, !data.isEmpty {
                self.handleIncomingData(data)
            }

            if !isComplete {
                self.startReceiving()
            }
        }
    }

    private func handleIncomingData(_ data: Data) {
        dataBuffer.append(data)
        processBufferedMessages()
    }

    private func processBufferedMessages() {
        while let newlineIndex = dataBuffer.firstIndex(of: 0x0A) {
            let lineData = dataBuffer.prefix(upTo: newlineIndex)
            dataBuffer.removeSubrange(...newlineIndex)

            if !lineData.isEmpty {
                do {
                    let json = try JSONSerialization.jsonObject(with: lineData, options: [])
                    if let jsonDict = json as? [String: Any] {
                        routeIncomingMessage(jsonDict)
                    }
                } catch {
                    print("Failed to parse JSON: \(error)")
                }
            }
        }
    }

    private func routeIncomingMessage(_ jsonData: [String: Any]) {
        let messageType = jsonData["type"] as! String

        switch messageType {
        case "ack":
            handleAckMessage(jsonData)
        case "handshake":
            handleHandshakeMessage(jsonData)
        default:
            fatalError("Unexpected message type: \(messageType)")
        }
    }

    private func handleAckMessage(_ jsonData: [String: Any]) {
        let logId = jsonData["logId"] as! String
        acknowledgeTransmission(for: logId)
    }

    private func handleHandshakeMessage(_ jsonData: [String: Any]) {
        sessionNumber = jsonData["sessionNumber"] as! Int
        sessionNumberSubject.send(sessionNumber)

        var totalLogs = 0
        var totalUptime = 0
        var todayUptime = 0

        if let logs = jsonData["totalLogs"] as? Int {
            totalLogs = logs
            totalLogsSubject.send(logs)
        }

        if let total = jsonData["totalUptime"] as? Int {
            totalUptime = total
            uptimeTotalSubject.send(total)
        }

        if let today = jsonData["todayUptime"] as? Int {
            todayUptime = today
            uptimeTodaySubject.send(today)
        }

        log("Successful handshake: Session #\(sessionNumber), Total: \(totalUptime)ms, Today: \(todayUptime)ms, Logs: \(totalLogs)")
    }

    private func acknowledgeTransmission(for logId: String) {
        _transmittedLogIds.append(logId)
        transmittedLogIdsSubject.send(_transmittedLogIds)
    }

    private func sendStartMessage() {
        let startMessage = ["type": "start"] as [String: Any]
        var jsonData = try! JSONSerialization.data(withJSONObject: startMessage)

        jsonData.append("\n".data(using: .utf8)!)

        connection.send(content: jsonData, completion: .contentProcessed { error in
            if let error = error {
                fatalError("Failed to send start message: \(error)")
            }
        })
    }
}

func log(
    _ message: String,
    file: String = #file,
    function: String = #function
) {
    Logger.shared.addLog(message, type: .log, file: file, function: function)
}

func error(
    _ message: String,
    file: String = #file,
    function: String = #function
) {
    Logger.shared.addLog(message, type: .error, file: file, function: function)
}
