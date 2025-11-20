import Foundation
@preconcurrency import AVFoundation
import Combine

enum APIState {
    case disconnected
    case connected
    case speechDetected
    case speechStopped
    case restarting
}

struct ConversationMessage: Identifiable, Sendable {
    let id = UUID()
    var text: String
    let role: String
    var audioState: MessageAudioState?
    var audioBuffers: [(Int, Data)] = []
}

protocol RealtimeAPIProtocol: Sendable {
    var apiStateSubject: CurrentValueSubject<APIState, Never> { get }
    var conversationContextSubject: CurrentValueSubject<[ConversationMessage], Never> { get }

    func connect(apiKey: String?)
    func acknowledgeSuccessfulPromptInjection()
    func acknowledgeSuccessfulInterruptExecution()
    func clearAccumulatedPrompts()
    func processInputAudioBuffer(_ data: Data)
    func restart()
    func addAssistantMessage(_ text: String)
}

nonisolated(unsafe) let realtimeAPI: RealtimeAPIProtocol = RealtimeAPI()

private class RealtimeAPI: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable, RealtimeAPIProtocol {
    let apiStateSubject = CurrentValueSubject<APIState, Never>(.disconnected)
    let conversationContextSubject = CurrentValueSubject<[ConversationMessage], Never>([])

    private let responseQueueThread = DispatchQueue(label: "com.realtimeapi.responsequeue", qos: .userInitiated)
    private var currentUserMessageId: UUID?

    private var isResponseActive: Bool = false
    private var responseRequestQueue: [(UUID, () -> Void)] = []
    private var currentProcessingMessageId: UUID?
    private var currentAudioSequenceNumber: Int = 0
    private var totalBytesReceived: Int = 0
    private var totalBytesSent: Int = 0
    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectAttempts: Int = 0
    private var reconnectTimer: DispatchSourceTimer?
    private var isReconnecting: Bool = false

    fileprivate override init() {
        super.init()
        log("WebSocketManager initialized")

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = 600.0

        self.urlSession = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: OperationQueue.main
        )

        if let existingApiKey = loadFromKeychain(key: "OPENAI_API_KEY") {
            log("Found existing API key in Keychain, auto-connecting")
            connect(apiKey: existingApiKey)
        }
    }

    func connect(apiKey: String?) {
        if let apiKey = apiKey {
            saveToKeychain(key: "OPENAI_API_KEY", value: apiKey)
        }

        guard let resolvedApiKey = loadFromKeychain(key: "OPENAI_API_KEY") else {
            error("No API key found in Keychain")
            return
        }

        if apiStateSubject.value == .connected || isReconnecting {
            log("Already connected or reconnecting, skipping connection attempt")
            return
        }

        isReconnecting = true

        log("Attempting to connect to OpenAI Realtime API")

        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime") else {
            error("Invalid WebSocket URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(resolvedApiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60.0

        log("Creating WebSocket task...")

        guard let session = self.urlSession else {
            error("URLSession not initialized")
            return
        }

        webSocketTask = session.webSocketTask(with: request)

        log("Starting WebSocket connection...")

        webSocketTask?.resume()

        log("WebSocket connection initiated - waiting for delegate callback")
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        log("WebSocket delegate: Connection opened")
        if let `protocol` = `protocol` {
            log("Using protocol: \(`protocol`)")
        }

        self.receiveMessage()
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        log("WebSocket closed with code: \(closeCode.rawValue)")
        updateAPIState(.disconnected)
        scheduleReconnect()
    }

    func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else {
                error("WebSocketManager deallocated during receive")
                return
            }

            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    debugLog(id: "receivedDataFromRealtime", message: "📥 [WS] Received data message")
                    self.handleDataMessage(data)
                case .string(let text):
                    debugLog(id: "receivedTextFromRealtime", message: "📥 [WS] Received text message")
                    self.handleTextMessage(text)
                @unknown default:
                    error("Received unknown message type")
                }

                self.receiveMessage()

            case .failure(let receiveError):
                self.handleError(receiveError)
            }
        }
    }

    func handleDataMessage(_ data: Data) {
        if let text = String(data: data, encoding: .utf8) {
            handleTextMessage(text)
        } else {
            error("Binary data received: \(data.count.formattedBytes) - cannot process")
        }
    }

    func handleTextMessage(_ text: String) {
        guard let json = parseJSON(from: text) else {
            return
        }

        guard let type = extractMessageType(from: json) else {
            error("Message missing 'type' field: \(text)")
            return
        }

        let messageSize = text.data(using: .utf8)?.count ?? 0
        totalBytesReceived += messageSize

        debugLog(id: "receivedFromRealtime",
                message: "📥 [WS] Received \(type): \(messageSize.formattedBytes) (total: \(totalBytesReceived.formattedBytes))")

        switch type {
        case "session.created":
            handleSessionCreated()
        case "session.updated":
            handleSessionUpdated()
        case "input_audio_buffer.speech_started":
            handleSpeechStarted()
        case "input_audio_buffer.speech_stopped":
            handleSpeechStopped()
        case "input_audio_buffer.committed":
            handleAudioBufferCommitted()
        case "response.created":
            handleResponseCreated(json)
        case "response.done":
            handleResponseDoneEvent(json)
        case "response.audio.delta":
            handleResponseAudioDelta(json)
        case "response.text.delta":
            handleResponseTextDelta(json)
        case "response.text.done":
            handleResponseTextDone(json)
        case "response.function_call_arguments.delta":
            handleResponseFunctionCallArgumentsDelta()
        case "response.function_call_arguments.done":
            handleFunctionCallArgumentsDone(json)
        case "response.output_text.delta":
            handleResponseOutputTextDelta()
        case "conversation.item.added":
            handleConversationItemAdded(json)
        case "response.output_audio.delta":
            handleResponseOutputAudioDelta(json)
        case "response.output_audio.done":
            handleResponseOutputAudioDone(json)
        case "response.output_audio_transcript.delta":
            handleResponseOutputAudioTranscriptDelta()
        case "response.output_audio_transcript.done":
            handleResponseOutputAudioTranscriptDone(json)
        case "conversation.item.done":
            handleConversationItemDone(json)
        case "response.output_item.added":
            handleResponseOutputItemAdded(json)
        case "response.content_part.added":
            handleResponseContentPartAdded(json)
        case "response.content_part.done":
            handleResponseContentPartDone()
        case "response.output_item.done":
            handleResponseOutputItemDone()
        case "rate_limits.updated":
            handleRateLimitsUpdated()
        case "conversation.item.input_audio_transcription.delta":
            handleConversationItemInputAudioTranscriptionDelta()
        case "conversation.item.input_audio_transcription.completed":
            handleConversationItemInputAudioTranscriptionCompleted()
        case "response.audio_transcript.delta":
            handleResponseAudioTranscriptDelta()
        case "error":
            handleErrorMessage(json)
        default:
            handleUnknownEventType(type, json)
        }
    }

    func parseJSON(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else {
            error("Failed to convert text to UTF-8 data")
            return nil
        }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                error("Failed to parse JSON as dictionary")
                return nil
            }
            return json
        } catch let parseError {
            error("JSON parsing error: \(parseError.localizedDescription)")
            return nil
        }
    }

    func extractMessageType(from json: [String: Any]) -> String? {
        return json["type"] as? String
    }

    func handleSessionCreated() {
        sendSessionUpdate()
    }

    func handleSessionUpdated() {
        updateAPIState(.connected)
        isReconnecting = false
        reconnectAttempts = 0
        cancelReconnectTimer()
        audioManager.startAudioEngine()
        processNextQueuedRequest()
    }

    func sendSessionUpdate() {
        let sessionUpdate: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "output_modalities": ["audio"],
                "instructions": """
                You are the voice interface for a fully accessible computer usage agent. This system uses GPT Realtime (you) on top of the Codex computer agent by OpenAI.

                Your role: You are ONLY the ears and mouth. Codex is the brain.

                Workflow:
                1. User speaks → you transcribe
                2. Transcription is submitted to the computer use agent for execution
                3. After successful submission, you read back a concise summary of the transcription to confirm that the transcription is correct
                4. Computer use agent executes the command and sends back a response prepended with "Computer use assistant message: [response]", which is added to your context
                5. You will be prompted to give an update of the last computer use assistant message (read it out concisely)

                Your knowledge: ONLY from messages prepended with "Computer use assistant message:". You have no other knowledge.
                """,
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24000
                        ],
                        "turn_detection": [
                            "type": "server_vad",
                            "threshold": 0.5,
                            "prefix_padding_ms": 100,
                            "silence_duration_ms": 200,
                            "create_response": false,
                            "interrupt_response": true
                        ],
                        "noise_reduction": [
                            "type": "near_field"
                        ]
                    ],
                    "output": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24000
                        ],
                        "voice": "alloy",
                        "speed": 1
                    ]
                ]
            ]
        ]

        send(event: sessionUpdate)
    }

    func send(event: [String: Any]) {
        guard let webSocketTask = webSocketTask else {
            debugLog(id: "sendError", message: "❌ [WS] Unable to send: WebSocket task is nil, skipping")
            return
        }

        let eventType = event["type"] as? String ?? "unknown"
        let isConnectionEvent = eventType == "session.update" || eventType == "session.create"

        if apiStateSubject.value == .disconnected && !isConnectionEvent {
            debugLog(id: "sendError", message: "❌ [WS] Unable to send \(eventType): Disconnected, skipping")
            return
        }

        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: event, options: [])
        } catch let serializationError {
            error("Failed to serialize event to JSON: \(serializationError.localizedDescription)")
            return
        }

        guard let text = String(data: data, encoding: .utf8) else {
            error("Failed to convert event data to UTF-8 string")
            return
        }

        let message = URLSessionWebSocketTask.Message.string(text)

        if eventType != "input_audio_buffer.append" {
            log("Sending event: \(eventType)")
        }

        totalBytesSent += data.count
        debugLog(id: "sendToRealtime",
                 message: "📤 [WS] Sending \(eventType): \(data.count.formattedBytes) (total: \(totalBytesSent.formattedBytes))")

        webSocketTask.send(message) { sendError in
            if let sendError = sendError {
                error("Failed to send \(eventType): \(sendError.localizedDescription)")
            } else if eventType != "input_audio_buffer.append" {
                log("Successfully sent: \(eventType)")
            }
        }
    }

    func handleSpeechStarted() {
        updateAPIState(.speechDetected)
        log("Voice activity detection started")
    }

    func handleSpeechStopped() {
        updateAPIState(.speechStopped)
        log("Voice activity detection stopped")
        callTranscriptionDeltaFunction()
    }

    func callTranscriptionDeltaFunction() {
        if currentUserMessageId == nil {
            let userMessage = ConversationMessage(
                text: "",
                role: "user",
                audioState: .queued
            )
            currentUserMessageId = userMessage.id

            var currentContext = conversationContextSubject.value
            currentContext.insert(userMessage, at: 0)
            conversationContextSubject.send(currentContext)
            log("Created new user message for transcription")
        }

        guard let userId = currentUserMessageId else {
            error("No current user message ID")
            return
        }

        queueResponseRequest(messageId: userId) { [weak self] in
            guard let self = self else { return }

            let responseCreate: [String: Any] = [
                "type": "response.create",
                "response": [
                    "tools": [
                        [
                            "type": "function",
                            "name": "transcriptionDelta",
                            "description": """
                            Whatever you heard since creating the last transcription. Please give an exact transcription of that.
                            """,
                            "parameters": [
                                "type": "object",
                                "properties": [
                                    "deltaTranscription": [
                                        "type": "string",
                                        "description": "Exact verbatim transcription of what was heard since the last delta transcription."
                                    ]
                                ],
                                "required": ["deltaTranscription"],
                                "additionalProperties": false,
                                "strict": true
                            ]
                        ]
                    ],
                    "tool_choice": "required"
                ]
            ]

            self.send(event: responseCreate)
            log("Requesting transcriptionDelta function call after speech stopped")
        }
    }

    func updateAPIState(_ newState: APIState) {
        let currentState = apiStateSubject.value

        let emoji: String
        switch newState {
        case .disconnected:
            emoji = "🔴"
        case .connected:
            emoji = "🔵"
        case .speechDetected:
            emoji = "🟡"
        case .speechStopped:
            emoji = "🟠"
        case .restarting:
            emoji = "⚪"
        }

        log("\(emoji) State transition: \(currentState) → \(newState)")
        responseQueueThread.async { [weak self] in
            self?.apiStateSubject.send(newState)
        }
    }

    func queueResponseRequest(messageId: UUID, _ request: @escaping () -> Void) {
        responseQueueThread.async { [weak self] in
            guard let self = self else { return }

            self.responseRequestQueue.append((messageId, request))
            log("Response queue: added request for message \(messageId) (total: \(self.responseRequestQueue.count))")

            if self.apiStateSubject.value != .disconnected {
                self.processNextQueuedRequest()
            }
        }
    }

    func handleAudioBufferCommitted() {
        log("Audio buffer committed")
    }

    func handleResponseCreated(_ json: [String: Any]) {
        if let response = json["response"] as? [String: Any],
           let status = response["status"] as? String {
            log("Response created - status: \(status)")
        } else {
            log("Response created")
        }
    }

    func handleResponseDoneEvent(_ json: [String: Any]) {
        guard let response = json["response"] as? [String: Any],
              let output = response["output"] as? [[String: Any]] else {
            error("Missing response or output in response.done")
            return
        }

        if let status = response["status"] as? String, status == "cancelled" {
            log("Response cancelled")
            markResponseComplete()
            return
        }

        guard let item = output.first else {
            log("Empty output array")
            markResponseComplete()
            return
        }

        guard let type = item["type"] as? String else {
            error("Missing type in output item")
            return
        }

        if type == "function_call" {
            guard let name = item["name"] as? String else {
                error("Missing name in function_call")
                return
            }

            let arguments = item["arguments"] as? String ?? "{}"
            let status = item["status"] as? String ?? ""

            var transcriptionValue = ""
            if let argData = arguments.data(using: .utf8),
               let argJson = try? JSONSerialization.jsonObject(with: argData) as? [String: Any],
               let delta = argJson["deltaTranscription"] as? String {
                transcriptionValue = delta
            }

            log("📞 Function Call - name: \(name), status: \(status), transcription: \(transcriptionValue)")

            if name == "transcriptionDelta" {
                updateLastPrompt(item)
            } else {
                log("Unexpected function - name: \(name)")
            }
        } else if type == "message" {
            handleAudioResponse(item)
        } else {
            log("Unexpected type: \(type)")
        }

        markResponseComplete()
    }

    func markResponseComplete() {
        log("✅ markResponseComplete() called")
        responseQueueThread.async { [weak self] in
            guard let self = self else { return }

            guard self.isResponseActive else {
                log("Response already completed (was function call)")
                return
            }

            self.updateMessageAudioState(messageId: self.currentProcessingMessageId, newState: .doneProcessing)
            self.currentProcessingMessageId = nil

            self.isResponseActive = false
            if self.responseRequestQueue.isEmpty && self.apiStateSubject.value != .connected && self.apiStateSubject.value == .speechStopped {
                self.updateAPIState(.connected)
            }
            self.processNextQueuedRequest()
        }
    }

    func processNextQueuedRequest() {
        responseQueueThread.async { [weak self] in
            guard let self = self else { return }

            guard !self.isResponseActive else {
                log("Response queue: already processing, not starting next")
                return
            }

            guard !self.responseRequestQueue.isEmpty else {
                log("Response queue: empty, nothing to process")
                return
            }

            let (messageId, nextRequest) = self.responseRequestQueue.removeFirst()
            self.currentProcessingMessageId = messageId
            self.currentAudioSequenceNumber = 0
            self.updateMessageAudioState(messageId: messageId, newState: .processing)
            log("Response queue: processing message \(messageId) (remaining: \(self.responseRequestQueue.count))")
            self.isResponseActive = true
            nextRequest()
        }
    }

    func handleResponseTextDelta(_ json: [String: Any]) {
        if let delta = json["delta"] as? String {
            debugLog(id: "textDelta", message: "📥 [WS] Text delta: \(delta)")
        }
    }

    func handleResponseTextDone(_ json: [String: Any]) {
        log("response.text.done event received")
    }

    func handleAudioResponse(_ json: [String: Any]) {
        guard let content = json["content"] as? [[String: Any]] else {
            return
        }

        for contentItem in content {
            guard let contentType = contentItem["type"] as? String,
                  contentType == "output_audio",
                  let transcript = contentItem["transcript"] as? String else {
                continue
            }

            log("🎤 Audio Output - transcript: \(transcript)")
        }
    }

    func updateLastPrompt(_ json: [String: Any]) {
        guard let arguments = json["arguments"] as? String else {
            log("Missing or invalid 'arguments' field in function call")
            return
        }

        guard let callId = json["call_id"] as? String else {
            log("Missing or invalid 'call_id' field in function call")
            return
        }

        guard let argumentsData = arguments.data(using: .utf8) else {
            log("Failed to convert arguments to UTF-8 data. Raw arguments: \(arguments)")
            return
        }

        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: argumentsData, options: [])
        } catch let parseError {
            log("Failed to parse function arguments as JSON: \(parseError.localizedDescription). Raw arguments: \(arguments)")
            return
        }

        guard let dict = jsonObject as? [String: Any] else {
            log("Function arguments not a dictionary. Raw arguments: \(arguments)")
            return
        }

        guard let deltaTranscription = dict["deltaTranscription"] as? String else {
            log("Discarding transcription. Dictionary: \(dict)")
            return
        }

        let transcription = deltaTranscription

        let filteredTranscription = transcription
            .replacingOccurrences(of: "\u{201C}", with: "")
            .replacingOccurrences(of: "\u{201D}", with: "")
            .replacingOccurrences(of: "\u{2018}", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")

        if filteredTranscription != transcription {
            debugLog(id: "transcriptionFiltered", message: "Filtered transcription: \(filteredTranscription)")
        }

        var currentContext = conversationContextSubject.value

        if let currentUserId = currentUserMessageId,
           let index = currentContext.firstIndex(where: { $0.id == currentUserId && $0.role == "user" }) {
            let currentText = currentContext[index].text
            let newValue = currentText.isEmpty ? filteredTranscription : currentText + "\n" + filteredTranscription
            currentContext[index].text = newValue
            conversationContextSubject.send(currentContext)
            log("Updated user message: added '\(filteredTranscription)'")
            log("Complete user message: \(newValue.replacingOccurrences(of: "\n", with: " "))")
        } else {
            let userMessage = ConversationMessage(
                text: filteredTranscription,
                role: "user",
                audioState: .queued
            )
            currentUserMessageId = userMessage.id
            currentContext.insert(userMessage, at: 0)
            conversationContextSubject.send(currentContext)
            log("Created new user message: \(filteredTranscription)")
        }

        let currentContext2 = conversationContextSubject.value
        let currentUserMessage = currentContext2.first(where: { $0.id == currentUserMessageId })
        let newValue = currentUserMessage?.text ?? ""

        let resultDict: [String: Any] = [
            "status": "success",
            "accumulated_transcription": newValue
        ]

        let outputData: Data
        do {
            outputData = try JSONSerialization.data(withJSONObject: resultDict)
        } catch let serializationError {
            error("Failed to serialize function result to JSON: \(serializationError.localizedDescription)")
            return
        }

        guard let outputString = String(data: outputData, encoding: .utf8) else {
            error("Failed to convert result data to UTF-8 string")
            return
        }

        let response: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": outputString
            ]
        ]

        send(event: response)
        log("Sent function output: \(outputString)")
    }

    func handleFunctionCallArgumentsDone(_ json: [String: Any]) {
        guard let name = json["name"] as? String else {
            log("Missing or invalid 'name' field in function call")
            return
        }

        guard let arguments = json["arguments"] as? String else {
            log("Missing or invalid 'arguments' field in function call")
            return
        }

        log("Function: \(name), Arguments: \(arguments)")
    }

    func handleConversationItemAdded(_ json: [String: Any]) {
        if let item = json["item"] as? [String: Any],
           let id = item["id"] as? String,
           let type = item["type"] as? String {
            debugLog(id: "conversationItem", message: "conversation.item.added: id=\(id), type=\(type)")
        }
    }

    func handleConversationItemDone(_ json: [String: Any]) {
        if let item = json["item"] as? [String: Any],
           let id = item["id"] as? String,
           let type = item["type"] as? String,
           let status = item["status"] as? String {
            debugLog(id: "conversationItem", message: "conversation.item.done: id=\(id), status=\(status)")

            if let role = item["role"] as? String, role == "assistant" {
                if type == "message",
                   status == "completed",
                   let content = item["content"] as? [[String: Any]],
                   let firstContent = content.first,
                   let contentType = firstContent["type"] as? String, contentType == "output_text" {
                    log("✅ Context item completed, advancing queue")
                    markResponseComplete()
                }
            }
        }
    }

    func handleResponseAudioDelta(_ json: [String: Any]) {
        debugLog(id: "audioDelta", message: "⚙️ [WS] Receiving audio delta (not scheduling)")
    }

    func handleResponseFunctionCallArgumentsDelta() {
        debugLog(id: "functionArgsDelta", message: "⚙️ [WS] Receiving function arguments")
    }

    func handleResponseOutputTextDelta() {
        debugLog(id: "textDelta", message: "⚙️ [WS] Receiving text output")
    }

    func handleResponseOutputAudioDelta(_ json: [String: Any]) {
        debugLog(id: "audioOutputDelta", message: "⚙️ [WS] Receiving audio output")
        guard let audioBase64 = json["delta"] as? String else {
            error("Missing or invalid 'delta' field in response.output_audio.delta")
            return
        }

        guard let audioData = Data(base64Encoded: audioBase64) else {
            error("Failed to decode audio delta")
            return
        }

        guard let messageId = currentProcessingMessageId else {
            error("No current processing message ID for audio buffer")
            return
        }

        var currentContext = conversationContextSubject.value
        guard let index = currentContext.firstIndex(where: { $0.id == messageId }) else {
            error("Cannot find message for audio buffer: \(messageId)")
            return
        }

        currentAudioSequenceNumber += 1
        currentContext[index].audioBuffers.append((currentAudioSequenceNumber, audioData))
        conversationContextSubject.send(currentContext)
    }

    func handleResponseOutputAudioDone(_ json: [String: Any]) {
        log("Audio output completed")
    }

    func handleResponseOutputAudioTranscriptDelta() {
        debugLog(id: "transcriptDelta", message: "📥 [WS] Transcript delta")
    }

    func handleResponseOutputAudioTranscriptDone(_ json: [String: Any]) {
        guard let transcript = json["transcript"] as? String else {
            error("Missing or invalid 'transcript' field in response.output_audio_transcript.done")
            return
        }
        log("Final transcript: \(transcript)")
    }

    func handleResponseContentPartAdded(_ json: [String: Any]) {
        guard let part = json["part"] as? [String: Any] else {
            error("Missing or invalid 'part' field in response.content_part.added")
            return
        }

        guard let type = part["type"] as? String else {
            error("Missing or invalid 'type' field in content part")
            return
        }

        log("response.content_part.added: type=\(type)")
    }

    func handleResponseContentPartDone() {
        log("Response content part done")
    }

    func handleResponseOutputItemDone() {
        log("Response output item done")
    }

    func handleRateLimitsUpdated() {
        log("Rate limits updated")
    }

    func handleConversationItemInputAudioTranscriptionDelta() {
        debugLog(id: "inputAudioTranscriptDelta", message: "⚙️ [WS] Input audio transcription delta")
    }

    func handleConversationItemInputAudioTranscriptionCompleted() {
        log("Input audio transcription completed")
    }

    func handleResponseAudioTranscriptDelta() {
        debugLog(id: "audioTranscriptDelta", message: "⚙️ [WS] Audio transcript delta")
    }

    func handleUnknownEventType(_ type: String, _ json: [String: Any]) {
        log("Unknown event type: \(type) - JSON: \(json)")
    }

    func handleResponseOutputItemAdded(_ json: [String: Any]) {
        guard let item = json["item"] as? [String: Any] else {
            error("Missing or invalid 'item' field in response.output_item.added")
            return
        }

        guard let itemType = item["type"] as? String else {
            error("Missing or invalid 'type' field in output item")
            return
        }

        debugLog(id: "outputItem", message: "response.output_item.added: type=\(itemType)")

        updateMessageAudioState(messageId: currentProcessingMessageId, newState: .processing)

        if itemType == "function_call" {
            guard let callId = item["call_id"] as? String else {
                error("Missing or invalid 'call_id' field in function_call output item")
                return
            }

            guard let name = item["name"] as? String else {
                error("Missing or invalid 'name' field in function_call output item")
                return
            }

            guard let status = item["status"] as? String else {
                error("Missing or invalid 'status' field in function_call output item")
                return
            }

            log("response.output_item.added: \(name) (\(status))")
        }
    }

    func handleErrorMessage(_ json: [String: Any]) {
        if let errorInfo = json["error"] as? [String: Any] {
            let errorType = errorInfo["type"] as? String ?? "unknown"
            let errorMessage = errorInfo["message"] as? String ?? "no message"
            error("Error type: \(errorType), message: \(errorMessage)")
        } else {
            error("Full error event: \(json)")
        }
    }

    func handleError(_ connectionError: Error) {
        let nsError = connectionError as NSError
        let errorMessage = formatConnectionError(nsError)
        log("❌ \(errorMessage)")
        updateAPIState(.disconnected)
        scheduleReconnect()
    }

    func formatConnectionError(_ nsError: NSError) -> String {
        switch nsError.code {
        case 57:
            return "WebSocket disconnected: Socket not connected"
        case 54:
            return "WebSocket disconnected: Connection reset by peer"
        default:
            return "WebSocket error: \(nsError.localizedDescription)"
        }
    }

    func processInputAudioBuffer(_ data: Data) {
        let base64Audio = data.base64EncodedString()

        let audioEvent: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64Audio
        ]

        send(event: audioEvent)
    }

    func requestTranscriptionConfirmation(message: ConversationMessage) {
        if !audioManager.getIsPlaybackEnabled() {
            log("Playback disabled, skipping transcription confirmation")
            return
        }

        queueResponseRequest(messageId: message.id) { [weak self] in
            guard let self = self else { return }

            let responseEvent: [String: Any] = [
                "type": "response.create",
                "response": [
                    "instructions": "Maximum three words only. Either a short sentence or just keywords to confirm the transcription.",
                    "output_modalities": ["audio"],
                    "max_output_tokens": 50
                ]
            ]
            self.send(event: responseEvent)
            log("Requesting one-word transcription confirmation for message: \(message.text)")
        }
    }

    func addAssistantMessage(_ text: String) {
        let message = ConversationMessage(
            text: text,
            role: "assistant",
            audioState: .queued
        )

        var currentContext = conversationContextSubject.value
        currentContext.insert(message, at: 0)
        conversationContextSubject.send(currentContext)

        log("Added assistant message to queue: \(text)")

        queueResponseRequest(messageId: message.id) { [weak self] in
            guard let self = self else { return }
            let contextText = "Computer use assistant message: \(text)"
            let conversationItem: [String: Any] = [
                "type": "conversation.item.create",
                "item": [
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        ["type": "output_text", "text": contextText]
                    ]
                ]
            ]
            self.send(event: conversationItem)
        }

        if audioManager.getIsPlaybackEnabled() {
            queueResponseRequest(messageId: message.id) { [weak self] in
                guard let self = self else { return }

                let responseEvent: [String: Any] = [
                    "type": "response.create",
                    "response": [
                        "instructions": "Maximum three words only. Summarize the action that was just taken by Codex, the terminal agent.",
                        "output_modalities": ["audio"],
                        "max_output_tokens": 50
                    ]
                ]
                self.send(event: responseEvent)
                log("Queued audio generation for assistant message")
            }
        } else {
            log("Playback disabled, skipping assistant message audio")
        }
    }

    func updateMessageAudioState(messageId: UUID?, newState: MessageAudioState) {
        guard let messageId = messageId else {
            log("⚠️ Cannot update message audio state: messageId is nil")
            return
        }

        var currentContext = conversationContextSubject.value
        guard let index = currentContext.firstIndex(where: { $0.id == messageId }) else {
            log("⚠️ Cannot update message audio state: message not found for id \(messageId)")
            return
        }

        currentContext[index].audioState = newState
        conversationContextSubject.send(currentContext)
        log("Updated message audio state to: \(newState.statusText)")
    }

    func acknowledgeSuccessfulPromptInjection() {
        guard let userId = currentUserMessageId else {
            log("No current user message to process - skipping transcription confirmation")
            return
        }

        var currentContext = conversationContextSubject.value
        guard let index = currentContext.firstIndex(where: { $0.id == userId }) else {
            log("Could not find user message in conversation context - skipping")
            return
        }

        currentContext[index].audioState = .queued
        conversationContextSubject.send(currentContext)

        let userMessage = currentContext[index]
        log("🧹 Processing user message for transcription confirmation: \(userMessage.text)")

        currentUserMessageId = nil

        requestTranscriptionConfirmation(message: userMessage)
    }

    func acknowledgeSuccessfulInterruptExecution() {
        log("🛑 Interrupt successfully executed - keeping accumulated prompts (interrupt doesn't clear them)")
    }

    func clearAccumulatedPrompts() {
        if let userId = currentUserMessageId {
            var currentContext = conversationContextSubject.value
            currentContext.removeAll(where: { $0.id == userId })
            conversationContextSubject.send(currentContext)
            currentUserMessageId = nil
            log("🗑️ Manually cleared current user message")
        } else {
            log("🗑️ No user message to clear")
        }
    }

    func restart() {
        updateAPIState(.restarting)
    }


    func disconnect() {
        updateAPIState(.disconnected)
        audioManager.stopAudioEngine()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        cancelReconnectTimer()
    }

    func scheduleReconnect() {
        guard loadFromKeychain(key: "OPENAI_API_KEY") != nil else {
            error("Cannot schedule reconnect: API key not in Keychain")
            return
        }

        cancelReconnectTimer()

        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(reconnectAttempts - 1)), 30.0)
        log("⏱️ Scheduling reconnection attempt \(reconnectAttempts) in \(String(format: "%.1f", delay))s")

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.attemptReconnect()
        }
        timer.resume()
        reconnectTimer = timer
    }

    func attemptReconnect() {
        log("🔄 Attempting reconnection (attempt \(reconnectAttempts))")

        audioManager.reset()

        conversationContextSubject.send([])
        currentUserMessageId = nil
        isResponseActive = false
        responseRequestQueue = []
        currentProcessingMessageId = nil
        currentAudioSequenceNumber = 0

        log("🗑️ Cleared conversation context for reconnection")

        connect(apiKey: nil)
    }

    func cancelReconnectTimer() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }

    func saveToKeychain(key: String, value: String) {
        guard let data = value.data(using: .utf8) else {
            error("Failed to encode keychain value as UTF8")
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]

        let deleteStatus = SecItemDelete(query as CFDictionary)
        log("Keychain delete status for \(key): \(deleteStatus)")

        let addStatus = SecItemAdd(query as CFDictionary, nil)

        guard addStatus == errSecSuccess else {
            error("Failed to save to keychain: \(addStatus)")
            return
        }

        log("Successfully saved \(key) to Keychain")
    }

    func loadFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                error("Failed to read from keychain: \(status)")
            }
            return nil
        }

        guard let data = result as? Data else {
            error("Keychain data is not Data type")
            return nil
        }

        guard let value = String(data: data, encoding: .utf8) else {
            error("Failed to decode keychain data as UTF8")
            return nil
        }

        log("Successfully loaded \(key) from Keychain")
        return value
    }

    deinit {
        cancelReconnectTimer()
        audioManager.stopAudioEngine()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        log("realtimeAPI deallocated")
    }
}
