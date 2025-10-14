/*
# REFACTORING DOCUMENT: Logger.swift

## Current State: ✅ PROPERLY ORDERED

### Struct: PromptStatusUpdate

#### Constants:
- prompt: String (public, let)
- status: String (public, let)

### Protocol: LoggerProtocol

#### Properties:
- logsSubject: CurrentValueSubject<[LogMessage], Never> (public, var)
- debugLogsSubject: CurrentValueSubject<[(LogMessage, Int)], Never> (public, var)
- transmittedLogIdsSubject: CurrentValueSubject<[String], Never> (public, var)
- sessionNumberSubject: CurrentValueSubject<Int, Never> (public, var)
- uptimeTodaySubject: CurrentValueSubject<Int, Never> (public, var)
- uptimeTotalSubject: CurrentValueSubject<Int, Never> (public, var)
- totalLogsSubject: CurrentValueSubject<Int, Never> (public, var)
- promptStatusSubject: PassthroughSubject<PromptStatusUpdate, Never> (public, var)

#### Functions:
Line 145: sendPromptToMac(_:) → (not documented in protocol)

### Enum: LogType (Codable)

#### Computed Properties:
Line 29: color: Color (public, get-only) → uses: self
Line 38: label: String (public, get-only) → uses: self

### Struct: LogMessage (Identifiable, Codable, Sendable)

#### Properties:
- id: String (public, var) → mutated in: init

#### Constants:
- type: LogType (public, let)
- timestamp: Date (public, let)
- fileName: String (public, let)
- functionName: String (public, let)
- message: String (public, let)

#### Computed Properties:
Line 55: shortFileName: String (public, get-only) → uses: fileName

### Global Variables:
Line 60: logger: LoggerProtocol (nonisolated unsafe, let)

### Class: Logger (@unchecked Sendable, LoggerProtocol, private)

#### Constants:
- connection: NWConnection (private, let) = NWConnection(to: "Felixs-MacBook-Pro.local:8082", using: .tcp)
- macHostname: String (private, let) = "Felixs-MacBook-Pro.local"
- port: UInt16 (private, let) = 8082
- tcpProcessingQueue: DispatchQueue (private, let) = DispatchQueue(label: "logger.tcp.processing", qos: .userInitiated)
- logsSubject: CurrentValueSubject<[LogMessage], Never> (public, let) = CurrentValueSubject([]) → sends: logsSubject.send(newArray) in addLogMessage
- transmittedLogIdsSubject: CurrentValueSubject<[String], Never> (public, let) = CurrentValueSubject([]) → sends: transmittedLogIdsSubject.send(updatedArray) in acknowledgeTransmission
- sessionNumberSubject: CurrentValueSubject<Int, Never> (public, let) = CurrentValueSubject(0) → sends: sessionNumberSubject.send(sessionNumber) in handleHandshakeMessage
- uptimeTodaySubject: CurrentValueSubject<Int, Never> (public, let) = CurrentValueSubject(0) → sends: uptimeTodaySubject.send(today) in handleHandshakeMessage
- uptimeTotalSubject: CurrentValueSubject<Int, Never> (public, let) = CurrentValueSubject(0) → sends: uptimeTotalSubject.send(total) in handleHandshakeMessage
- totalLogsSubject: CurrentValueSubject<Int, Never> (public, let) = CurrentValueSubject(0) → sends: totalLogsSubject.send(logs) in handleHandshakeMessage
- debugLogsSubject: CurrentValueSubject<[(LogMessage, Int)], Never> (public, let) = CurrentValueSubject([]) → sends: debugLogsSubject.send(updatedArray) in addDebugLog
- promptStatusSubject: PassthroughSubject<PromptStatusUpdate, Never> (public, let) = PassthroughSubject() → sends: in handlePromptAckMessage, sendPromptToMac

#### Properties:
- dataBuffer: Data (private, var) = Data() → mutated in: handleIncomingData(append data), processAllBufferedMessages(removeSubrange)
- totalBytesReceived: Int (private, var) = 0 → mutated in: init(0), handleIncomingData(+= data.count)
- totalBytesSentToMac: Int (private, var) = 0 → mutated in: init(0), sendMessage(+= jsonData.count)
- sessionNumber: Int (private, var) = 0 → mutated in: handleHandshakeMessage(= from JSON)

#### Functions:
Line 206: init() → NWConnection.init(), connection.start()

Line 226: addLog(_:type:file:function:) → LogMessage.init(), addLogMessage(), sendLog()

Line 244: addLogMessage(_:) → logsSubject.send()

Line 250: sendLog(_:) → JSONEncoder.init(), sendMessage()

Line 258: sendMessage(_:messageType:logMessage:) → tcpProcessingQueue.async(), connection.send()
  → debug: "📤 [iOS→macOS] Sending \(messageType): \(jsonData.count.formattedBytes) (total: \(self.totalBytesSentToMac.formattedBytes))"

Line 282: addDebugLog(id:message:file:function:) → LogMessage.init(), debugLogsSubject.send()

Line 304: startReceiving() → connection.receive(), tcpProcessingQueue.async(), handleIncomingData(), startReceiving()

Line 324: handleIncomingData(_:) → dataBuffer.append(), processAllBufferedMessages()
  → debug: "📥 [TCP] Buffered packet: \(data.count.formattedBytes) (buffer: \(dataBuffer.count.formattedBytes), total: \(totalBytesReceived.formattedBytes))"

Line 334: processAllBufferedMessages() → dataBuffer.firstIndex(), dataBuffer.removeSubrange(), JSONSerialization.jsonObject(), routeIncomingMessage()
  → debug: "⚙️ [TCP] Processed \(messagesProcessed) messages (\(dataBuffer.count.formattedBytes) remaining)"

Line 359: routeIncomingMessage(_:) → JSONSerialization.data(), handleAckMessage(), handleHandshakeMessage(), handlePromptAckMessage()
  → debug: "📥 [macOS→iOS] Received \(messageType): \(messageSize.formattedBytes) (total: \(totalBytesReceived.formattedBytes))"

Line 380: handleAckMessage(_:) → acknowledgeTransmission()
  → debug: "✅ [TCP] ACK received for log: \(logId)"

Line 392: handleHandshakeMessage(_:) → realtimeAPI.connect(), sessionNumberSubject.send(), totalLogsSubject.send(), uptimeTotalSubject.send(), uptimeTodaySubject.send()
  → log: "Successful handshake: Session #\(sessionNumber), Total: \(totalUptime)ms, Today: \(todayUptime)ms, Logs: \(totalLogs)"

Line 386: acknowledgeTransmission(for:) → transmittedLogIdsSubject.send()

Line 422: handlePromptAckMessage(_:) → realtimeAPI.realTimeApiAcknowledgeSuccessful(), promptStatusSubject.send()
  → log: "✅ Prompt successfully injected into terminal"
  → log: "📝 Complete prompt executed: \(originalPrompt)"
  → error: "❌ Failed to inject prompt: \(errorMessage)"

Line 439: sendStartMessage() → JSONSerialization.data(), sendMessage()
  → log: "📤 [iOS → macOS] Sending start message"

Line 446: sendPromptToMac(_:) → JSONSerialization.data(), sendMessage(), promptStatusSubject.send()
  → log: "📤 [iOS → macOS] Sending prompt: \(prompt)"

### Global Functions:
Line 461: log(_:file:function:) → Logger.addLog()

Line 469: error(_:file:function:) → Logger.addLog()

Line 477: debugLog(id:message:file:function:) → Logger.addDebugLog()
*/

import Foundation
import SwiftUI
import Network
import Combine

struct PromptStatusUpdate {
    let prompt: String
    let status: String
}

protocol LoggerProtocol {
    var logsSubject: CurrentValueSubject<[LogMessage], Never> { get }
    var debugLogsSubject: CurrentValueSubject<[(LogMessage, Int)], Never> { get }
    var transmittedLogIdsSubject: CurrentValueSubject<[String], Never> { get }
    var sessionNumberSubject: CurrentValueSubject<Int, Never> { get }
    var uptimeTodaySubject: CurrentValueSubject<Int, Never> { get }
    var uptimeTotalSubject: CurrentValueSubject<Int, Never> { get }
    var totalLogsSubject: CurrentValueSubject<Int, Never> { get }
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
        URL(fileURLWithPath: fileName).lastPathComponent
    }
}

nonisolated(unsafe) let logger: LoggerProtocol = Logger()

private class Logger: @unchecked Sendable, LoggerProtocol {

    let debugLogsSubject = CurrentValueSubject<[(LogMessage, Int)], Never>([])
    let logsSubject = CurrentValueSubject<[LogMessage], Never>([])
    let promptStatusSubject = PassthroughSubject<PromptStatusUpdate, Never>()
    let sessionNumberSubject = CurrentValueSubject<Int, Never>(0)
    let totalLogsSubject = CurrentValueSubject<Int, Never>(0)
    let transmittedLogIdsSubject = CurrentValueSubject<[String], Never>([])
    let uptimeTodaySubject = CurrentValueSubject<Int, Never>(0)
    let uptimeTotalSubject = CurrentValueSubject<Int, Never>(0)

    private let connection: NWConnection
    private let macHostname = "Felixs-MacBook-Pro.local"
    private let port: UInt16 = 8082
    private let tcpProcessingQueue = DispatchQueue(label: "logger.tcp.processing", qos: .userInitiated)

    private var dataBuffer = Data()
    private var sessionNumber: Int = 0
    private var totalBytesReceived: Int = 0
    private var totalBytesSentToMac: Int = 0

    fileprivate init() {

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

    private func acknowledgeTransmission(for logId: String) {
        var currentIds = transmittedLogIdsSubject.value
        currentIds.append(logId)
        transmittedLogIdsSubject.send(currentIds)
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

    private func handlePromptAckMessage(_ jsonData: [String: Any]) {
        let status = jsonData["status"] as! String
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

    private func sendStartMessage() {
        let startMessage = ["type": "start"] as [String: Any]
        let jsonData = try! JSONSerialization.data(withJSONObject: startMessage)

        sendMessage(jsonData, messageType: "start", logMessage: "📤 [iOS → macOS] Sending start message")
    }

    func sendPromptToMac(_ prompt: String) {
        let promptMessage: [String: Any] = [
            "type": "prompt",
            "prompt": prompt,
            "timestamp": Date().timeIntervalSince1970
        ]

        let jsonData = try! JSONSerialization.data(withJSONObject: promptMessage)

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
