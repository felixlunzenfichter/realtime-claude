import Foundation
import SwiftUI
import Network
import Combine

protocol LoggerProtocol {
    var logsSubject: CurrentValueSubject<[LogMessage], Never> { get }
    var debugLogsSubject: CurrentValueSubject<[(LogMessage, Int)], Never> { get }
    var transmittedLogIdsSubject: CurrentValueSubject<[String], Never> { get }
    var sessionNumberSubject: CurrentValueSubject<Int, Never> { get }
    var uptimeTodaySubject: CurrentValueSubject<Int, Never> { get }
    var uptimeTotalSubject: CurrentValueSubject<Int, Never> { get }
    var totalLogsSubject: CurrentValueSubject<Int, Never> { get }

    func sendPromptToMac(_ prompt: String, category: String)
}

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
    var id: String = UUID().uuidString
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

class Logger: @unchecked Sendable, LoggerProtocol {
    nonisolated(unsafe) static let shared: LoggerProtocol = Logger()

    private let connection: NWConnection
    private let macHostname = "Felixs-MacBook-Pro.local"
    private let port: UInt16 = 8082
    private var dataBuffer = Data()
    private let tcpProcessingQueue = DispatchQueue(label: "logger.tcp.processing", qos: .userInitiated)

    let logsSubject = CurrentValueSubject<[LogMessage], Never>([])
    let transmittedLogIdsSubject = CurrentValueSubject<[String], Never>([])
    let sessionNumberSubject = CurrentValueSubject<Int, Never>(0)
    let uptimeTodaySubject = CurrentValueSubject<Int, Never>(0)
    let uptimeTotalSubject = CurrentValueSubject<Int, Never>(0)
    let totalLogsSubject = CurrentValueSubject<Int, Never>(0)
    let debugLogsSubject = CurrentValueSubject<[(LogMessage, Int)], Never>([])

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

    func addDebugLog(id: String, message: String, file: String, function: String) {
        let logMessage = LogMessage(
            id: id,
            type: .log,
            timestamp: Date(),
            fileName: file,
            functionName: function,
            message: message
        )

        var debugLogs = debugLogsSubject.value

        if let index = debugLogs.firstIndex(where: { $0.0.id == id }) {
            let (_, count) = debugLogs[index]
            debugLogs[index] = (logMessage, count + 1)
        } else {
            debugLogs.insert((logMessage, 1), at: 0)
        }

        debugLogsSubject.send(debugLogs)
    }

    private func addLogMessage(_ logMessage: LogMessage) {
        var currentLogs = logsSubject.value
        currentLogs.insert(logMessage, at: 0)
        logsSubject.send(currentLogs)
    }

    private func sendLog(_ logMessage: LogMessage) {
        tcpProcessingQueue.async { [weak self] in
            guard let self = self else { return }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601

            var jsonData = try! encoder.encode(logMessage)

            jsonData.append("\n".data(using: .utf8)!)

            debugLog(id: "sendLog", message: "Sending to Mac server: \(logMessage.message) (ID: \(logMessage.id))")

            self.connection.send(content: jsonData, completion: .contentProcessed { error in
                if let error = error {
                    fatalError("Failed to send log: \(error)")
                }
            })
        }
    }

    private func startReceiving() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                fatalError("Logger receive failed: \(error)")
            }

            if let data = data, !data.isEmpty {
                self.tcpProcessingQueue.async {
                    self.handleIncomingData(data)
                }
            }

            if !isComplete {
                self.startReceiving()
            }
        }
    }

    private func handleIncomingData(_ data: Data) {
        dataBuffer.append(data)
        debugLog(id: "tcp-buffer", message: "Buffer size: \(dataBuffer.count) bytes after appending \(data.count) bytes")
        processAllBufferedMessages()
    }

    private func processAllBufferedMessages() {
        var messagesProcessed = 0

        while let newlineIndex = dataBuffer.firstIndex(of: 0x0A) {
            let lineData = dataBuffer.prefix(upTo: newlineIndex)
            dataBuffer.removeSubrange(...newlineIndex)

            if !lineData.isEmpty {
                do {
                    let json = try JSONSerialization.jsonObject(with: lineData, options: [])
                    if let jsonDict = json as? [String: Any] {
                        routeIncomingMessage(jsonDict)
                        messagesProcessed += 1
                    }
                } catch {
                    fatalError("Failed to parse JSON: \(error)")
                }
            }
        }

        if messagesProcessed > 0 {
            debugLog(id: "tcp-process", message: "Processed \(messagesProcessed) messages, \(dataBuffer.count) bytes remaining in buffer")
        }
    }

    private func routeIncomingMessage(_ jsonData: [String: Any]) {
        let messageType = jsonData["type"] as! String

        switch messageType {
        case "ack":
            handleAckMessage(jsonData)
        case "handshake":
            handleHandshakeMessage(jsonData)
        case "prompt_ack":
            handlePromptAckMessage(jsonData)
        default:
            fatalError("Unexpected message type: \(messageType)")
        }
    }

    private func handleAckMessage(_ jsonData: [String: Any]) {
        let logId = jsonData["logId"] as! String
        debugLog(id: "ack", message: "Received ACK from Mac server for log ID: \(logId)")
        acknowledgeTransmission(for: logId)
    }

    private func handleHandshakeMessage(_ jsonData: [String: Any]) {
        if let apiKey = jsonData["apiKey"] as? String {
            RealtimeAPI.shared.connect(apiKey: apiKey)
        }

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
        var currentIds = transmittedLogIdsSubject.value
        currentIds.append(logId)
        transmittedLogIdsSubject.send(currentIds)
    }

    private func handlePromptAckMessage(_ jsonData: [String: Any]) {
        let status = jsonData["status"] as! String
        let originalPrompt = jsonData["originalPrompt"] as? String ?? "Unknown prompt"

        if status == "success" {
            log("✅ Prompt successfully injected into terminal: \(originalPrompt)")
        } else {
            let errorMessage = jsonData["error"] as? String ?? "Unknown error"
            error("❌ Failed to inject prompt: \(errorMessage)")
        }
    }

    private func sendStartMessage() {
        tcpProcessingQueue.async { [weak self] in
            guard let self = self else { return }

            let startMessage = ["type": "start"] as [String: Any]
            var jsonData = try! JSONSerialization.data(withJSONObject: startMessage)

            jsonData.append("\n".data(using: .utf8)!)

            self.connection.send(content: jsonData, completion: .contentProcessed { error in
                if let error = error {
                    fatalError("Failed to send start message: \(error)")
                }
            })
        }
    }

    func sendPromptToMac(_ prompt: String, category: String) {
        tcpProcessingQueue.async { [weak self] in
            guard let self = self else { return }

            let promptMessage: [String: Any] = [
                "type": "prompt",
                "prompt": prompt,
                "category": category,
                "timestamp": Date().timeIntervalSince1970
            ]

            var jsonData = try! JSONSerialization.data(withJSONObject: promptMessage)
            jsonData.append("\n".data(using: .utf8)!)

            self.connection.send(content: jsonData, completion: .contentProcessed { error in
                if let error = error {
                    fatalError("Failed to send prompt to Mac: \(error)")
                } else {
                    log("Sent prompt to Mac server: \(prompt)")
                }
            })
        }
    }
}

func log(
    _ message: String,
    file: String = #file,
    function: String = #function
) {
    (Logger.shared as! Logger).addLog(message, type: .log, file: file, function: function)
}

func error(
    _ message: String,
    file: String = #file,
    function: String = #function
) {
    (Logger.shared as! Logger).addLog(message, type: .error, file: file, function: function)
}

func debugLog(
    id: String,
    message: String,
    file: String = #file,
    function: String = #function
) {
    (Logger.shared as! Logger).addDebugLog(id: id, message: message, file: file, function: function)
}
