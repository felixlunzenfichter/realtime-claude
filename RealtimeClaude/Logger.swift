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

struct TranscriptionSegment: Sendable {
    let start: Double
    let end: Double
    let text: String
    let noSpeechProb: Double
}

struct TranscriptionUpdate {
    let transcription: String
    let prompt: String?
    let summary: String?
    let isFinal: Bool
    let isRaw: Bool
    let status: String
    let segments: [TranscriptionSegment]
    let messageId: UUID?
}

protocol LoggerProtocol {
    var logsSubject: CurrentValueSubject<[LogMessage], Never> { get }
    var debugLogsSubject: CurrentValueSubject<[(LogMessage, Int)], Never> { get }
    var transmittedLogIdsSubject: CurrentValueSubject<[String], Never> { get }
    var sessionStatsSubject: CurrentValueSubject<SessionStats, Never> { get }
    var testsPassedSubject: CurrentValueSubject<Int, Never> { get }
    var promptStatusSubject: PassthroughSubject<PromptStatusUpdate, Never> { get }
    var transcriptionSubject: PassthroughSubject<TranscriptionUpdate, Never> { get }
    var macConnectionReadySubject: CurrentValueSubject<Bool, Never> { get }

    func sendPromptToMac(_ prompt: String, messageId: UUID)
    func sendAudioToMac(_ audioData: Data, isStart: Bool, isEnd: Bool, messageId: UUID?)
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
    let transcriptionSubject = PassthroughSubject<TranscriptionUpdate, Never>()
    let macConnectionReadySubject = CurrentValueSubject<Bool, Never>(false)

    private var connection: NWConnection
    private let macHostname = "Felixs-MacBook-Pro.local"
    private let port: UInt16 = 8082
    private let tcpProcessingQueue = DispatchQueue(label: "logger.tcp.processing", qos: .userInitiated)
    private var reconnectAttempts: Int = 0
    private var reconnectTimer: DispatchSourceTimer?
    private var ackTimeoutTimer: DispatchSourceTimer?
    private var isConnectionReady: Bool = false {
        didSet {
            macConnectionReadySubject.send(isConnectionReady)
        }
    }

    private let TEST_DEFINITIONS: [Int: String] = [
        1: "Successful handshake",
        2: "Prompt successfully injected into terminal",
        3: "Started playing response",
        4: "Stopped playing response"
    ]

    private var dataBuffer = Data()
    private var totalBytesReceived: Int = 0
    private var totalBytesSentToMac: Int = 0

    fileprivate init() {
        let portValue = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(integerLiteral: 8082)
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(macHostname), port: portValue)
        connection = NWConnection(to: endpoint, using: .tcp)

        setupConnection()
    }

    private func setupConnection() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }

            switch state {
            case .ready:
                log("Connected to Mac server")
                self.isConnectionReady = true
                self.reconnectAttempts = 0
                self.cancelReconnectTimer()
                self.startReceiving()
                self.sendStartMessage()
            case .failed(let connectionError):
                log("Logger connection failed: \(connectionError)")
                self.isConnectionReady = false
                self.scheduleReconnect()
            case .waiting(let waitError):
                log("Waiting to connect to Mac: \(waitError)")
                self.isConnectionReady = false
                self.scheduleReconnect()
            case .cancelled:
                self.isConnectionReady = false
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

            guard self.isConnectionReady else {
                return
            }

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
                    let nsError = sendError as NSError
                    if nsError.code != 89 {
                        log("❌ Failed to send \(messageType): \(sendError)")
                        self.isConnectionReady = false
                        self.scheduleReconnect()
                    }
                } else {
                    self.startAckTimeoutTimer()
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
                log("Logger receive failed: \(receiveError)")
                self.isConnectionReady = false
                self.scheduleReconnect()
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
        case "transcription":
            handleTranscriptionMessage(jsonData)
        default:
            error("Unexpected message type: \(messageType)")
        }
    }

    private func handleAckMessage(_ jsonData: [String: Any]) {
        guard let logId = jsonData["logId"] as? String else {
            error("logId was nil in ACK message")
            return
        }

        cancelAckTimeoutTimer()
        realtimeAPI.connect()

        debugLog(id: "ackReceived", message: "✅ [TCP] ACK received for log: \(logId)")

        let currentLogs = logsSubject.value
        if let logMessage = currentLogs.first(where: { $0.id == logId }) {
            let nextTestNumber = testsPassedSubject.value + 1
            if let testString = TEST_DEFINITIONS[nextTestNumber],
               logMessage.message.contains(testString) {
                testsPassedSubject.send(nextTestNumber)
                log("✅ Test \(nextTestNumber) passed: \(testString)")
            }

            if logMessage.type == .error && logMessage.message == "Manual restart triggered from log view" {
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
            realtimeAPI.saveAPIKey(apiKey)
        }

        guard let sessionNumber = jsonData["sessionNumber"] as? Int else {
            error("sessionNumber was nil in handshake message")
            return
        }

        let totalLogs = jsonData["totalLogs"] as? Int ?? 0
        let totalUptime = jsonData["totalUptime"] as? Int ?? 0
        let todayUptime = jsonData["todayUptime"] as? Int ?? 0

        if let currentAssistantMessage = jsonData["currentAssistantMessage"] as? String,
           let summary = jsonData["currentAssistantMessageSummary"] as? String {
            realtimeAPI.addAssistantMessage(currentAssistantMessage, summary: summary)
            log("Loaded assistant message from handshake with TTS: \"\(summary)\"")
        }

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
        guard let summary = jsonData["summary"] as? String else {
            error("Missing summary in prompt ACK message")
            return
        }

        if status == "success" {
            log("✅ Prompt successfully injected into terminal: \(originalPrompt)")
            log("   Summary: \(summary)")
            promptStatusSubject.send(PromptStatusUpdate(prompt: originalPrompt, status: "injected"))

            if originalPrompt == "[Request interrupted by user]" {
                realtimeAPI.acknowledgeSuccessfulInterruptExecution()
            } else {
                guard let messageIdString = jsonData["messageId"] as? String,
                      let messageId = UUID(uuidString: messageIdString) else {
                    error("Missing or invalid messageId in prompt ACK message")
                    return
                }
                realtimeAPI.acknowledgeSuccessfulPromptInjection(summary: summary, messageId: messageId)
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
            guard let text = message["text"] as? String,
                  let summary = message["summary"] as? String else {
                continue
            }
            realtimeAPI.addAssistantMessage(text, summary: summary)
        }
    }

    private func handleTranscriptionMessage(_ jsonData: [String: Any]) {
        debugLog(id: "promptFlow", message: "handleTranscriptionMessage() called, JSON keys: \(jsonData.keys.joined(separator: ", "))")

        let status = jsonData["status"] as? String ?? "transcription"
        let isFinal = status == "prompt" || status == "summary"
        let isRaw = status == "transcription" || status == "final_chunk"

        let transcription = jsonData["transcription"] as? String ?? ""
        let prompt = jsonData["prompt"] as? String
        let summary = jsonData["summary"] as? String

        debugLog(id: "promptFlow", message: "Parsed: status='\(status)', transcription='\(transcription)', prompt='\(prompt ?? "nil")', summary='\(summary ?? "nil")', isFinal=\(isFinal), isRaw=\(isRaw)")

        var messageId: UUID? = nil
        if let messageIdString = jsonData["messageId"] as? String {
            messageId = UUID(uuidString: messageIdString)
            debugLog(id: "promptFlow", message: "messageId = \(messageIdString)")
        } else {
            debugLog(id: "promptFlow", message: "messageId = nil")
        }

        var segments: [TranscriptionSegment] = []
        if let segmentsData = jsonData["segments"] as? [[String: Any]] {
            segments = segmentsData.compactMap { segmentDict in
                guard let start = segmentDict["start"] as? Double,
                      let end = segmentDict["end"] as? Double,
                      let text = segmentDict["text"] as? String,
                      let noSpeechProb = segmentDict["no_speech_prob"] as? Double else {
                    return nil
                }
                return TranscriptionSegment(start: start, end: end, text: text, noSpeechProb: noSpeechProb)
            }
        }

        if transcription.isEmpty {
            error("Transcription is EMPTY in transcription message, aborting")
            return
        }

        if status == "transcription" {
            log("📥 [TRANSCRIPTION] \(transcription)")
        } else if status == "prompt" {
            log("📥 [PROMPT] Raw: \(transcription) | Prompt: \(prompt ?? "none")")
        } else if status == "summary" {
            log("📥 [SUMMARY] Raw: \(transcription) | Prompt: \(prompt ?? "none")")
            if let summary = summary {
                log("   Summary: \(summary)")
            }
        } else if status == "final_chunk" {
            log("📥 [FINAL_CHUNK] \(transcription)")
        } else {
            debugLog(id: "transcription", message: "🎤 [\(status)] \(prompt ?? transcription)")
        }

        debugLog(id: "promptFlow", message: "Sending to transcriptionSubject: status='\(status)', transcription='\(transcription)', prompt='\(prompt ?? "nil")', summary='\(summary ?? "nil")', isFinal=\(isFinal), isRaw=\(isRaw), messageId=\(messageId?.uuidString ?? "nil")")

        transcriptionSubject.send(TranscriptionUpdate(
            transcription: transcription,
            prompt: prompt,
            summary: summary,
            isFinal: isFinal,
            isRaw: isRaw,
            status: status,
            segments: segments,
            messageId: messageId
        ))

        debugLog(id: "promptFlow", message: "TranscriptionUpdate sent to transcriptionSubject")
    }

    private func sendStartMessage() {
        let startMessage = ["type": "start"] as [String: Any]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: startMessage) else {
            error("Failed to serialize start message to JSON")
            return
        }

        sendMessage(jsonData, messageType: "start", logMessage: "📤 [iOS → macOS] Sending start message")
    }

    func sendPromptToMac(_ prompt: String, messageId: UUID) {
        let promptMessage: [String: Any] = [
            "type": "prompt",
            "prompt": prompt,
            "messageId": messageId.uuidString,
            "timestamp": Date().timeIntervalSince1970
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: promptMessage) else {
            error("Failed to serialize prompt message to JSON")
            return
        }

        sendMessage(jsonData, messageType: "prompt", logMessage: "📤 [iOS → macOS] Sending prompt: \(prompt) (messageId: \(messageId.uuidString))")

        promptStatusSubject.send(PromptStatusUpdate(prompt: prompt, status: "sent"))
    }

    func sendAudioToMac(_ audioData: Data, isStart: Bool = false, isEnd: Bool = false, messageId: UUID? = nil) {
        var audioMessage: [String: Any] = [
            "type": "audio",
            "audioData": audioData.base64EncodedString()
        ]

        if isStart {
            audioMessage["isStart"] = true
        }
        if isEnd {
            audioMessage["isEnd"] = true
        }
        if let messageId = messageId {
            audioMessage["messageId"] = messageId.uuidString
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: audioMessage) else {
            error("Failed to serialize audio message to JSON")
            return
        }

        let flags = isStart ? " (START)" : (isEnd ? " (END)" : "")
        sendMessage(jsonData, messageType: "audio\(flags)")
    }

    private func scheduleReconnect() {
        cancelReconnectTimer()

        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(reconnectAttempts - 1)), 30.0)
        log("⏱️ Scheduling Mac reconnection attempt \(reconnectAttempts) in \(String(format: "%.1f", delay))s")

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.attemptReconnect()
        }
        timer.resume()
        reconnectTimer = timer
    }

    private func attemptReconnect() {
        log("🔄 Attempting Mac reconnection (attempt \(reconnectAttempts))")

        connection.cancel()

        guard let portValue = NWEndpoint.Port(rawValue: port) else {
            log("❌ Invalid port number: \(port)")
            return
        }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(macHostname), port: portValue)
        connection = NWConnection(to: endpoint, using: .tcp)

        setupConnection()
    }

    private func cancelReconnectTimer() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }

    private func startAckTimeoutTimer() {
        cancelAckTimeoutTimer()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 5.0)
        timer.setEventHandler { [weak self] in
            self?.handleAckTimeout()
        }
        timer.resume()
        ackTimeoutTimer = timer
    }

    private func cancelAckTimeoutTimer() {
        ackTimeoutTimer?.cancel()
        ackTimeoutTimer = nil
    }

    private func handleAckTimeout() {
        realtimeAPI.disconnect()
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
