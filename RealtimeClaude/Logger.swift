import Foundation
import SwiftUI
import Network
import Combine
import UIKit

struct SessionStats {
    let sessionNumber: Int
    let totalUptime: Int
    let todayUptime: Int
    let totalLogs: Int
    let totalTests: Int
    let previousRunFailed: Bool
}

struct PromptStatusUpdate {
    let prompt: String
    let status: String
}

protocol LoggerProtocol {
    var logsSubject: CurrentValueSubject<[LogMessage], Never> { get }
    var debugLogsSubject: CurrentValueSubject<[(LogMessage, Int)], Never> { get }
    var transmittedLogIdsSubject: CurrentValueSubject<[String], Never> { get }
    var sessionStatsSubject: CurrentValueSubject<SessionStats, Never> { get }
    var testsPassedSubject: CurrentValueSubject<Int, Never> { get }
    var promptStatusSubject: PassthroughSubject<PromptStatusUpdate, Never> { get }

    func sendPromptToMac(_ prompt: String)
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
        URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
    }
}

nonisolated(unsafe) let logger: LoggerProtocol = Logger()

private class Logger: @unchecked Sendable, LoggerProtocol {

    let debugLogsSubject = CurrentValueSubject<[(LogMessage, Int)], Never>([])
    let logsSubject = CurrentValueSubject<[LogMessage], Never>([])
    let promptStatusSubject = PassthroughSubject<PromptStatusUpdate, Never>()
    let sessionStatsSubject = CurrentValueSubject<SessionStats, Never>(SessionStats(sessionNumber: 0, totalUptime: 0, todayUptime: 0, totalLogs: 0, totalTests: 0, previousRunFailed: false))
    let testsPassedSubject = CurrentValueSubject<Int, Never>(0)
    let transmittedLogIdsSubject = CurrentValueSubject<[String], Never>([])

    private let connection: NWConnection
    private let macHostname = "Felixs-MacBook-Pro.local"
    private let port: UInt16 = 8082
    private let tcpProcessingQueue = DispatchQueue(label: "logger.tcp.processing", qos: .userInitiated)

    private let TEST_DEFINITIONS: [Int: String] = [
        1: "Successful handshake",
        2: "WebSocket connection established",
        3: "Voice activity detection started",
        4: "Voice activity detection stopped",
        5: "Prompt successfully injected into terminal",
        6: "Started playing response",
        7: "Stopped playing response"
    ]

    private var dataBuffer = Data()
    private var passedTestNumbers: Set<Int> = []
    private var totalBytesReceived: Int = 0
    private var totalBytesSentToMac: Int = 0

    fileprivate init() {

        guard let portValue = NWEndpoint.Port(rawValue: port) else {
            fatalError("Invalid port number: \(port)")
        }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(macHostname), port: portValue)
        connection = NWConnection(to: endpoint, using: .tcp)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.startReceiving()
                self.sendStartMessage()
            case .failed(let connectionError):
                error("Logger connection failed: \(connectionError)")
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
        var currentLogs = logsSubject.value
        currentLogs.insert(logMessage, at: 0)
        logsSubject.send(currentLogs)
    }

    private func sendLog(_ logMessage: LogMessage) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try! encoder.encode(logMessage)

        sendMessage(jsonData, messageType: "log")
    }

    private func sendMessage(_ data: Data, messageType: String, logMessage: String? = nil) {
        tcpProcessingQueue.async { [weak self] in
            guard let self = self else { return }

            guard let newlineData = "\n".data(using: .utf8) else {
                error("Failed to convert newline to UTF-8 data")
                return
            }

            var jsonData = data
            jsonData.append(newlineData)

            self.totalBytesSentToMac += jsonData.count

            debugLog(id: "macosOutgoing",
                    message: "📤 [iOS→macOS] Sending \(messageType): \(jsonData.count.formattedBytes) (total: \(self.totalBytesSentToMac.formattedBytes))")

            if let logMessage = logMessage {
                log(logMessage)
            }

            self.connection.send(content: jsonData, completion: .contentProcessed { sendError in
                if let sendError = sendError {
                    error("Failed to send \(messageType): \(sendError)")
                }
            })
        }
    }

    func addDebugLog(id: String, message: String, file: String, function: String) {
        var debugLogs = debugLogsSubject.value

        if let index = debugLogs.firstIndex(where: { $0.0.id == id }) {
            let (existingLog, count) = debugLogs[index]
            let now = Date()
            let timeSinceLastUpdate = now.timeIntervalSince(existingLog.timestamp)
            let newTimestamp = timeSinceLastUpdate > 1.0 ? now : existingLog.timestamp

            let updatedLog = LogMessage(
                id: id,
                type: .log,
                timestamp: newTimestamp,
                fileName: file,
                functionName: function,
                message: message
            )
            debugLogs[index] = (updatedLog, count + 1)
        } else {
            let logMessage = LogMessage(
                id: id,
                type: .log,
                timestamp: Date(),
                fileName: file,
                functionName: function,
                message: message
            )
            debugLogs.insert((logMessage, 1), at: 0)
        }

        debugLogsSubject.send(debugLogs)
    }

    private func startReceiving() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, receiveError in
            guard let self = self else { return }

            if let receiveError = receiveError {
                error("Logger receive failed: \(receiveError)")
                return
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
        totalBytesReceived += data.count

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
                } catch let parseError {
                    error("Failed to parse JSON: \(parseError)")
                }
            }
        }

        if messagesProcessed > 0 {
            debugLog(id: "tcpProcess", message: "⚙️ [TCP] Processed \(messagesProcessed) messages (\(dataBuffer.count.formattedBytes) remaining)")
        }
    }

    private func routeIncomingMessage(_ jsonData: [String: Any]) {
        guard let messageType = jsonData["type"] as? String else {
            error("type was nil in incoming message")
            return
        }

        guard let jsonBytes = try? JSONSerialization.data(withJSONObject: jsonData) else {
            error("Failed to serialize incoming message to JSON")
            return
        }

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
        case "assistant_messages":
            handleAssistantMessages(jsonData)
        default:
            error("Unexpected message type: \(messageType)")
        }
    }

    private func handleAckMessage(_ jsonData: [String: Any]) {
        guard let logId = jsonData["logId"] as? String else {
            error("logId was nil in ACK message")
            return
        }

        debugLog(id: "ackReceived", message: "✅ [TCP] ACK received for log: \(logId)")

        let currentLogs = logsSubject.value
        if let logMessage = currentLogs.first(where: { $0.id == logId }) {
            for (testNumber, testString) in TEST_DEFINITIONS.sorted(by: { $0.key < $1.key }) {
                if !passedTestNumbers.contains(testNumber) && logMessage.message.contains(testString) {
                    passedTestNumbers.insert(testNumber)
                    testsPassedSubject.send(testNumber)
                    log("✅ Test \(testNumber) passed: \(testString)")
                    break
                }
            }

            if logMessage.type == .error {
                showRestartAlert(fileName: logMessage.shortFileName, functionName: logMessage.functionName, message: logMessage.message)
            }
        }

        acknowledgeTransmission(for: logId)
    }

    private func acknowledgeTransmission(for logId: String) {
        var currentIds = transmittedLogIdsSubject.value
        currentIds.append(logId)
        transmittedLogIdsSubject.send(currentIds)
    }

    private func showRestartAlert(fileName: String, functionName: String, message: String) {
        realtimeAPI.restart()
    }

    private func handleHandshakeMessage(_ jsonData: [String: Any]) {
        if let apiKey = jsonData["apiKey"] as? String {
            realtimeAPI.connect(apiKey: apiKey)
        }

        guard let sessionNumber = jsonData["sessionNumber"] as? Int else {
            error("sessionNumber was nil in handshake message")
            return
        }

        let totalLogs = jsonData["totalLogs"] as? Int ?? 0
        let totalUptime = jsonData["totalUptime"] as? Int ?? 0
        let todayUptime = jsonData["todayUptime"] as? Int ?? 0

        var previousRunFailed = false
        if let previousErrors = jsonData["previousErrors"] as? [[String: Any]], !previousErrors.isEmpty {
            previousRunFailed = true

            let errorDescriptions = previousErrors.compactMap { errorDict -> String? in
                guard let message = errorDict["message"] as? String,
                      let fileName = errorDict["fileName"] as? String,
                      let functionName = errorDict["functionName"] as? String else {
                    return nil
                }

                let shortFileName = (fileName as NSString).lastPathComponent
                return "  • \(shortFileName) → \(functionName)\n    \(message)"
            }

            let errorList = errorDescriptions.joined(separator: "\n\n")
            log("Previous run failed:\n\n\(errorList)")
        }

        let sessionStats = SessionStats(
            sessionNumber: sessionNumber,
            totalUptime: totalUptime,
            todayUptime: todayUptime,
            totalLogs: totalLogs,
            totalTests: TEST_DEFINITIONS.count,
            previousRunFailed: previousRunFailed
        )

        sessionStatsSubject.send(sessionStats)

        log("Successful handshake: Session #\(sessionNumber), Total: \(totalUptime)ms, Today: \(todayUptime)ms, Logs: \(totalLogs)")
    }

    private func handlePromptAckMessage(_ jsonData: [String: Any]) {
        guard let status = jsonData["status"] as? String else {
            error("status was nil in prompt ACK message")
            return
        }

        let originalPrompt = jsonData["originalPrompt"] as? String ?? "Unknown prompt"

        if status == "success" {
            log("✅ Prompt successfully injected into terminal: \(originalPrompt)")
            promptStatusSubject.send(PromptStatusUpdate(prompt: originalPrompt, status: "injected"))

            if originalPrompt == "[Request interrupted by user]" {
                realtimeAPI.acknowledgeSuccessfulInterruptExecution()
            } else {
                realtimeAPI.acknowledgeSuccessfulPromptInjection()
            }
        } else {
            let errorMessage = jsonData["error"] as? String ?? "Unknown error"
            error("❌ Failed to inject prompt: \(errorMessage)")
            promptStatusSubject.send(PromptStatusUpdate(prompt: originalPrompt, status: "failed"))
        }
    }

    private func handleAssistantMessages(_ jsonData: [String: Any]) {
        guard let messages = jsonData["messages"] as? [[String: Any]] else {
            error("messages was nil in assistant_messages")
            return
        }

        log("📨 Received \(messages.count) assistant messages from Mac")

        for message in messages {
            guard let text = message["text"] as? String else {
                continue
            }
            realtimeAPI.readAssistantMessage(text)
        }
    }

    private func sendStartMessage() {
        let startMessage = ["type": "start"] as [String: Any]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: startMessage) else {
            error("Failed to serialize start message to JSON")
            return
        }

        sendMessage(jsonData, messageType: "start", logMessage: "📤 [iOS → macOS] Sending start message")
    }

    func sendPromptToMac(_ prompt: String) {
        let promptMessage: [String: Any] = [
            "type": "prompt",
            "prompt": prompt,
            "timestamp": Date().timeIntervalSince1970
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: promptMessage) else {
            error("Failed to serialize prompt message to JSON")
            return
        }

        sendMessage(jsonData, messageType: "prompt", logMessage: "📤 [iOS → macOS] Sending prompt: \(prompt)")

        promptStatusSubject.send(PromptStatusUpdate(prompt: prompt, status: "sent"))
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
