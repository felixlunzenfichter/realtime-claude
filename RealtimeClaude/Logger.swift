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

    var shortFileName: String {
        URL(fileURLWithPath: fileName).lastPathComponent
    }
}

nonisolated(unsafe) let logger: LoggerProtocol = Logger()

private class Logger: @unchecked Sendable, LoggerProtocol {

    private let connection: NWConnection
    private let macHostname = "Felixs-MacBook-Pro.local"
    private let port: UInt16 = 8082
    private var dataBuffer = Data()
    private var totalBytesReceived: Int = 0
    private var totalBytesSentToMac: Int = 0
    private let tcpProcessingQueue = DispatchQueue(label: "logger.tcp.processing", qos: .userInitiated)

    let logsSubject = CurrentValueSubject<[LogMessage], Never>([])
    let transmittedLogIdsSubject = CurrentValueSubject<[String], Never>([])
    let sessionNumberSubject = CurrentValueSubject<Int, Never>(0)
    let uptimeTodaySubject = CurrentValueSubject<Int, Never>(0)
    let uptimeTotalSubject = CurrentValueSubject<Int, Never>(0)
    let totalLogsSubject = CurrentValueSubject<Int, Never>(0)
    let debugLogsSubject = CurrentValueSubject<[(LogMessage, Int)], Never>([])

    private var sessionNumber: Int = 0

    fileprivate init() {
        
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(macHostname), port: NWEndpoint.Port(rawValue: port)!)
        connection = NWConnection(to: endpoint, using: .tcp)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.totalBytesReceived = 0
                self.totalBytesSentToMac = 0
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

    private func sendMessage(_ data: Data, messageType: String, logMessage: String? = nil) {
        tcpProcessingQueue.async { [weak self] in
            guard let self = self else { return }

            var jsonData = data
            jsonData.append("\n".data(using: .utf8)!)

            self.totalBytesSentToMac += jsonData.count

            debugLog(id: "macosOutgoing",
                    message: "📤 [iOS→macOS] Sending \(messageType): \(jsonData.count.formattedBytes) (total: \(self.totalBytesSentToMac.formattedBytes))")

            if let logMessage = logMessage {
                log(logMessage)
            }

            self.connection.send(content: jsonData, completion: .contentProcessed { error in
                if let error = error {
                    fatalError("Failed to send \(messageType): \(error)")
                }
            })
        }
    }

    private func sendLog(_ logMessage: LogMessage) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try! encoder.encode(logMessage)

        sendMessage(jsonData, messageType: "log")
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
        // Append the new data
        dataBuffer.append(data)

        // Update total bytes received since connection started
        totalBytesReceived += data.count

        // Log format: Show only sizes
        debugLog(id: "tcpBuffer",
                 message: "📥 [TCP] Buffered packet: \(data.count.formattedBytes) (buffer: \(dataBuffer.count.formattedBytes), total: \(totalBytesReceived.formattedBytes))")

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
            debugLog(id: "tcpProcess", message: "⚙️ [TCP] Processed \(messagesProcessed) messages (\(dataBuffer.count.formattedBytes) remaining)")
        }
    }

    private func routeIncomingMessage(_ jsonData: [String: Any]) {
        let messageType = jsonData["type"] as! String

        let jsonBytes = try! JSONSerialization.data(withJSONObject: jsonData)
        let messageSize = jsonBytes.count

        debugLog(id: "macosIncoming",
                message: "📥 [macOS→iOS] Received \(messageType): \(messageSize.formattedBytes) (total: \(totalBytesReceived.formattedBytes))")

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
        debugLog(id: "ackReceived", message: "✅ [TCP] ACK received for log: \(logId)")
        acknowledgeTransmission(for: logId)
    }

    private func handleHandshakeMessage(_ jsonData: [String: Any]) {
        if let apiKey = jsonData["apiKey"] as? String {
            realtimeAPI.connect(apiKey: apiKey)
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

            // Return function call result to OpenAI
            if let callId = realtimeAPI.currentFunctionCallId {
                let result: [String: Any] = [
                    "status": "success",
                    "message": "Prompt successfully injected into CLAUDE terminal and executing. (prompt: \(originalPrompt))"
                ]
                realtimeAPI.sendFunctionCallResult(callId: callId, result: result)
            }
        } else {
            let errorMessage = jsonData["error"] as? String ?? "Unknown error"
            error("❌ Failed to inject prompt: \(errorMessage)")

            // Return function call error to OpenAI
            if let callId = realtimeAPI.currentFunctionCallId {
                let result: [String: Any] = [
                    "status": "error",
                    "message": "Failed to inject prompt: \(errorMessage)"
                ]
                realtimeAPI.sendFunctionCallResult(callId: callId, result: result)
            }
        }
    }

    private func sendStartMessage() {
        let startMessage = ["type": "start"] as [String: Any]
        let jsonData = try! JSONSerialization.data(withJSONObject: startMessage)

        sendMessage(jsonData, messageType: "start", logMessage: "📤 [iOS → macOS] Sending start message")
    }

    func sendPromptToMac(_ prompt: String, category: String) {
        let promptMessage: [String: Any] = [
            "type": "prompt",
            "prompt": prompt,
            "category": category,
            "timestamp": Date().timeIntervalSince1970
        ]

        let jsonData = try! JSONSerialization.data(withJSONObject: promptMessage)

        sendMessage(jsonData, messageType: "prompt", logMessage: "📤 [iOS → macOS] Sending prompt: \(prompt)")
    }
}

func log(
    _ message: String,
    file: String = #file,
    function: String = #function
) {
    (logger as! Logger).addLog(message, type: .log, file: file, function: function)
}

func error(
    _ message: String,
    file: String = #file,
    function: String = #function
) {
    (logger as! Logger).addLog(message, type: .error, file: file, function: function)
}

func debugLog(
    id: String,
    message: String,
    file: String = #file,
    function: String = #function
) {
    (logger as! Logger).addDebugLog(id: id, message: message, file: file, function: function)
}
