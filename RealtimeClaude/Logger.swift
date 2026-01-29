import Foundation
import SwiftUI
import Network
import Combine

struct SessionStats {
    let sessionNumber: Int
    let totalUptime: Int
    let todayUptime: Int
    let totalLogs: Int
    let totalTests: Int
}

protocol LoggerProtocol {
    var logsSubject: CurrentValueSubject<[LogMessage], Never> { get }
    var debugLogsSubject: CurrentValueSubject<[(LogMessage, Int)], Never> { get }
    var transmittedLogIdsSubject: CurrentValueSubject<[String], Never> { get }
    var sessionStatsSubject: CurrentValueSubject<SessionStats, Never> { get }
    var testsPassedSubject: CurrentValueSubject<Int, Never> { get }
    var macConnectionReadySubject: CurrentValueSubject<Bool, Never> { get }
    var codeDiffSubject: CurrentValueSubject<String, Never> { get }
    var claudeIsActiveSubject: CurrentValueSubject<Bool, Never> { get }
    var planPendingSubject: CurrentValueSubject<String?, Never> { get }

    func sendPromptToMac(_ prompt: String, messageId: UUID)
    func sendAudioToMac(_ audioData: Data, isStart: Bool, isEnd: Bool, messageId: UUID?)
    func sendDeleteToMac(messageId: UUID)
    func sendPlanAcceptedToMac()
    func sendPlanRejectedToMac()
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
enum LogMode: String, Codable, Sendable {
    case auto = "AUTO"
    case manual = "MANUAL"
    case prod = "PROD"

    static var current: LogMode {
        #if IS_TEST
            #if MANUAL_TESTING
                return .manual
            #else
                return .auto
            #endif
        #else
            return .prod
        #endif
    }
}

enum LogDevice: String, Codable, Sendable {
    case iPhone = "iPhone"
    case iPad = "iPad"

    private nonisolated(unsafe) static var _cachedDevice: LogDevice?

    @MainActor
    private static func detectDevice() -> LogDevice {
        UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
    }

    static var current: LogDevice {
        if let cached = _cachedDevice {
            return cached
        }
        let device: LogDevice
        if Thread.isMainThread {
            device = MainActor.assumeIsolated { detectDevice() }
        } else {
            device = DispatchQueue.main.sync {
                MainActor.assumeIsolated { detectDevice() }
            }
        }
        _cachedDevice = device
        return device
    }
}

struct LogMessage: Identifiable, Codable, Sendable {
    var id: String = UUID().uuidString
    let type: LogType
    let timestamp: Date
    let fileName: String
    let functionName: String
    let message: String
    let mode: LogMode
    let device: LogDevice

    var shortFileName: String {
        URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
    }
}

nonisolated(unsafe) let logger: LoggerProtocol = Logger()

private class Logger: @unchecked Sendable, LoggerProtocol {

    let debugLogsSubject = CurrentValueSubject<[(LogMessage, Int)], Never>([])
    let logsSubject = CurrentValueSubject<[LogMessage], Never>([])
    let sessionStatsSubject = CurrentValueSubject<SessionStats, Never>(SessionStats(sessionNumber: 0, totalUptime: 0, todayUptime: 0, totalLogs: 0, totalTests: 0))
    let testsPassedSubject = CurrentValueSubject<Int, Never>(0)
    let transmittedLogIdsSubject = CurrentValueSubject<[String], Never>([])
    let macConnectionReadySubject = CurrentValueSubject<Bool, Never>(false)
    let codeDiffSubject = CurrentValueSubject<String, Never>("")
    let claudeIsActiveSubject = CurrentValueSubject<Bool, Never>(false)
    let planPendingSubject = CurrentValueSubject<String?, Never>(nil)

    private var connection: NWConnection
    private let macHostname = "100.73.64.63"
    #if IS_TEST
    private let port: UInt16 = 9999
    #else
    private let port: UInt16 = 8082
    #endif
    private let tcpProcessingSendingQueue = DispatchQueue(label: "logger.tcp.processing.sending", qos: .userInitiated)
    private let tcpProcessingReceivingQueue = DispatchQueue(label: "logger.tcp.processing.receiving", qos: .userInitiated)
    private var reconnectAttempts: Int = 0
    private var reconnectTimer: DispatchSourceTimer?

    #if IS_TEST
    private static let TEST_WORD = "MOONLIGHT"

    private static let TEST_0_MARKER = "✓ TEST[0] PASSED: handshake"
    private static let TEST_1_MARKER = "✓ TEST[1] PASSED: claude_responds"
    private static let TEST_2_MARKER = "✓ TEST[2] PASSED: recall_verified"

    private let STORY: [(command: String?, result: String)] = [
        (nil, Logger.TEST_0_MARKER),
        ("Remember \(TEST_WORD)", Logger.TEST_1_MARKER),
        ("What word did I ask you to remember?", Logger.TEST_2_MARKER)
    ]

    private var storyIndex = 0
    private var isCheckingStory = false

    func testHandshakePassed() {
        guard storyIndex == 0 else { return }
        testsPassedSubject.send(testsPassedSubject.value + 1)
        log(Logger.TEST_0_MARKER)
    }

    func testClaudeRespondsPassed() {
        guard storyIndex == 1 else { return }
        testsPassedSubject.send(testsPassedSubject.value + 1)
        log(Logger.TEST_1_MARKER)
    }

    func testRecallVerified(_ response: String) {
        guard storyIndex == 2 else { return }
        guard !response.isEmpty else { return }
        testsPassedSubject.send(testsPassedSubject.value + 1)
        log(Logger.TEST_2_MARKER)
    }

    private func pre(_ condition: Bool, _ message: String) {
        if !condition { error("PRE: \(message)") }
    }

    private func post(_ condition: Bool, _ message: String) {
        if !condition { error("POST: \(message)") }
    }

    private func inv(_ condition: Bool, _ message: String) {
        if !condition { error("INV: \(message)") }
    }

    private func checkStoryProgress(_ loggedMessage: String) {
        guard !isCheckingStory else { return }
        guard !loggedMessage.hasPrefix("📖") else { return }

        isCheckingStory = true
        defer { isCheckingStory = false }

        inv(storyIndex >= 0, "storyIndex must be non-negative")
        inv(storyIndex <= STORY.count, "storyIndex must not exceed STORY.count")

        guard storyIndex < STORY.count else { return }

        let expected = STORY[storyIndex].result

        if loggedMessage.contains(expected) {
            log("📖 Story[\(storyIndex)] matched: \(expected)")
            storyIndex += 1
            advanceStory()
        }
    }

    private func advanceStory() {
        pre(storyIndex >= 0, "storyIndex must be non-negative")

        guard storyIndex < STORY.count else {
            log("✅ Story complete")
            return
        }

        let step = STORY[storyIndex]
        log("📖 Story[\(storyIndex)] waiting for: \(step.result)")

        #if !MANUAL_TESTING
        if let command = step.command {
            log("📖 Executing command: \(command)")
            executeCommand(command)
        }
        #endif
    }

    #if !MANUAL_TESTING
    private func executeCommand(_ command: String) {
        pre(!command.isEmpty, "command must not be empty")
        log("📤 Sending prompt to Mac: \(command)")
        sendPromptToMac(command, messageId: UUID())
    }
    #endif

    #else
    func testHandshakePassed() {}
    func testClaudeRespondsPassed() {}
    func testRecallVerified(_ response: String) {}
    #endif

    private var isConnectionReady: Bool = false {
        didSet {
            macConnectionReadySubject.send(isConnectionReady)
            if isConnectionReady {
                realtimeAPI.connect()
            } else {
                realtimeAPI.disconnect()
            }
        }
    }


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

            self.tcpProcessingSendingQueue.async {
                switch state {
                case .ready:
                    log("Connected to Mac server")
                    self.isConnectionReady = true
                    self.reconnectAttempts = 0
                    self.cancelReconnectTimer()
                    self.startReceiving()
                    self.sendStartMessage()
                    #if IS_TEST
                    self.advanceStory()
                    #endif
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
            message: message,
            mode: LogMode.current,
            device: LogDevice.current
        )

        addLogMessage(logMessage)
        sendLog(logMessage)

        #if IS_TEST
        checkStoryProgress(message)
        #endif
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
        tcpProcessingSendingQueue.async { [weak self] in
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
                message: message,
                mode: LogMode.current,
                device: LogDevice.current
            )
            debugLogs[index] = (updatedLog, count + 1)
        } else {
            let logMessage = LogMessage(
                id: id,
                type: .log,
                timestamp: Date(),
                fileName: file,
                functionName: function,
                message: message,
                mode: LogMode.current,
                device: LogDevice.current
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
                self.tcpProcessingReceivingQueue.async {
                    self.handleIncomingData(data)
                }
            }

            if isComplete {
                log("TCP connection marked complete - receive loop ending")
            } else {
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
                    let preview = String(data: lineData.prefix(100), encoding: .utf8) ?? "binary"
                    error("Failed to parse JSON: \(parseError) - data preview: \(preview)")
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
        case "transcription":
            handleTranscriptionMessage(jsonData)
        case "prompt":
            handlePromptMessage(jsonData)
        case "summary":
            handleSummaryMessage(jsonData)
        case "assistant":
            handleAssistantMessage(jsonData)
        case "code_diff":
            handleCodeDiffMessage(jsonData)
        case "claude_state":
            handleClaudeStateMessage(jsonData)
        case "plan_pending":
            handlePlanPendingMessage(jsonData)
        default:
            error("Unexpected message type: \(messageType)")
        }
    }

    private func handleAckMessage(_ jsonData: [String: Any]) {
        guard let logId = jsonData["logId"] as? String else {
            error("logId was nil in ACK message")
            return
        }
        acknowledgeTransmission(for: logId)
    }

    private func acknowledgeTransmission(for logId: String) {
        var currentIds = transmittedLogIdsSubject.value
        currentIds.append(logId)
        transmittedLogIdsSubject.send(currentIds)
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
           let summary = jsonData["currentAssistantMessageSummary"] as? String,
           !currentAssistantMessage.isEmpty,
           !summary.isEmpty,
           let messageIdString = jsonData["messageId"] as? String,
           let messageId = UUID(uuidString: messageIdString) {
            realtimeAPI.updatePrompt(messageId: messageId, text: currentAssistantMessage)
            realtimeAPI.updateSummary(messageId: messageId, text: summary)
            log("Loaded assistant message from handshake with TTS: \"\(summary)\"")
        }

        if let previousErrors = jsonData["previousErrors"] as? [[String: Any]], !previousErrors.isEmpty {
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

        #if IS_TEST
        let totalTests = STORY.count
        #else
        let totalTests = 0
        #endif

        let sessionStats = SessionStats(
            sessionNumber: sessionNumber,
            totalUptime: totalUptime,
            todayUptime: todayUptime,
            totalLogs: totalLogs,
            totalTests: totalTests
        )

        sessionStatsSubject.send(sessionStats)

        log("Successful handshake: Session #\(sessionNumber), Total: \(totalUptime)ms, Today: \(todayUptime)ms, Logs: \(totalLogs)")

        #if IS_TEST
        testHandshakePassed()
        #endif
    }

    private func handleTranscriptionMessage(_ jsonData: [String: Any]) {
        guard let transcription = jsonData["transcription"] as? String else {
            error("Missing transcription in transcription message")
            return
        }

        guard let messageIdString = jsonData["messageId"] as? String,
              let messageId = UUID(uuidString: messageIdString) else {
            error("Missing or invalid messageId in transcription message")
            return
        }

        if transcription.isEmpty {
            error("Transcription is EMPTY in transcription message, aborting")
            return
        }

        log("📥 [MESSAGE] transcription: \(transcription)")

        realtimeAPI.updateTranscription(messageId: messageId, text: transcription)
    }

    private func handlePromptMessage(_ jsonData: [String: Any]) {
        guard let prompt = jsonData["prompt"] as? String else {
            error("Missing prompt in prompt message")
            return
        }

        guard let messageIdString = jsonData["messageId"] as? String,
              let messageId = UUID(uuidString: messageIdString) else {
            error("Missing or invalid messageId in prompt message")
            return
        }

        log("📥 [MESSAGE] prompt: \(prompt)")

        realtimeAPI.updatePrompt(messageId: messageId, text: prompt)
    }

    private func handleSummaryMessage(_ jsonData: [String: Any]) {
        guard let summary = jsonData["summary"] as? String else {
            error("Missing summary in summary message")
            return
        }

        guard let messageIdString = jsonData["messageId"] as? String,
              let messageId = UUID(uuidString: messageIdString) else {
            error("Missing or invalid messageId in summary message")
            return
        }

        log("📥 [MESSAGE] summary: \(summary)")

        realtimeAPI.updateSummary(messageId: messageId, text: summary)
    }

    private func handleAssistantMessage(_ jsonData: [String: Any]) {
        guard let prompt = jsonData["prompt"] as? String,
              let summary = jsonData["summary"] as? String,
              let messageIdString = jsonData["messageId"] as? String,
              let messageId = UUID(uuidString: messageIdString) else {
            error("Missing required fields in assistant message")
            return
        }

        log("📥 [MESSAGE] assistant: \(summary)")

        realtimeAPI.updatePrompt(messageId: messageId, text: prompt)
        realtimeAPI.updateSummary(messageId: messageId, text: summary)

        #if IS_TEST
        testClaudeRespondsPassed()
        testRecallVerified(prompt)
        #endif
    }

    private func handleCodeDiffMessage(_ jsonData: [String: Any]) {
        guard let diff = jsonData["diff"] as? String else {
            error("diff was nil in code_diff message")
            return
        }

        codeDiffSubject.send(diff)
        log("📥 Received git diff: \(diff.isEmpty ? "empty" : "\(diff.split(separator: "\n").count) lines")")
    }

    private func handleClaudeStateMessage(_ jsonData: [String: Any]) {
        guard let isActive = jsonData["isActive"] as? Bool else {
            error("isActive was nil in claude_state message")
            return
        }

        log("📡 Claude state: \(isActive ? "active" : "inactive")")
        claudeIsActiveSubject.send(isActive)
        realtimeAPI.updateClaudeActiveState(isActive)
    }

    private func handlePlanPendingMessage(_ jsonData: [String: Any]) {
        guard let message = jsonData["message"] as? String else {
            error("message was nil in plan_pending message")
            return
        }

        log("📋 Plan pending: \(message)")
        planPendingSubject.send(message)
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

    func sendDeleteToMac(messageId: UUID) {
        let deleteMessage: [String: Any] = [
            "type": "delete",
            "messageId": messageId.uuidString
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: deleteMessage) else {
            error("Failed to serialize delete message to JSON")
            return
        }

        sendMessage(jsonData, messageType: "delete", logMessage: "📤 [iOS → macOS] Sending delete for messageId: \(messageId.uuidString)")
    }

    func sendPlanAcceptedToMac() {
        let acceptMessage: [String: Any] = [
            "type": "plan_accepted"
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: acceptMessage) else {
            error("Failed to serialize plan_accepted message to JSON")
            return
        }

        sendMessage(jsonData, messageType: "plan_accepted", logMessage: "📤 [iOS → macOS] Plan accepted")
        planPendingSubject.send(nil)
    }

    func sendPlanRejectedToMac() {
        let rejectMessage: [String: Any] = [
            "type": "plan_rejected"
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: rejectMessage) else {
            error("Failed to serialize plan_rejected message to JSON")
            return
        }

        sendMessage(jsonData, messageType: "plan_rejected", logMessage: "📤 [iOS → macOS] Plan rejected")
        planPendingSubject.send(nil)
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
