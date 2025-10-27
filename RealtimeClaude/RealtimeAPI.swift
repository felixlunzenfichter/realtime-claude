import Foundation
@preconcurrency import AVFoundation
import Combine

enum APIState {
    case disconnected
    case connected
    case speechDetected
    case speechStopped
    case processing
}

protocol RealtimeAPIProtocol: Sendable {
    var apiStateSubject: CurrentValueSubject<APIState, Never> { get }
    var lastPromptSubject: CurrentValueSubject<String, Never> { get }

    func connect(apiKey: String)
    func acknowledgeSuccessfulPromptInjection()
    func acknowledgeSuccessfulInterruptExecution()
    func clearAccumulatedPrompts()
    func processInputAudioBuffer(_ data: Data)
}

nonisolated(unsafe) let realtimeAPI: RealtimeAPIProtocol = RealtimeAPI()

private class RealtimeAPI: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable, RealtimeAPIProtocol {
    let apiStateSubject = CurrentValueSubject<APIState, Never>(.disconnected)
    let lastPromptSubject = CurrentValueSubject<String, Never>("")

    private let responseQueueThread = DispatchQueue(label: "com.realtimeapi.responsequeue", qos: .userInitiated)

    private var currentFunctionCallId: String?
    private var isResponseActive: Bool = false
    private var responseRequestQueue: [() -> Void] = []
    private var totalBytesReceived: Int = 0
    private var totalBytesSent: Int = 0
    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?

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
    }

    func connect(apiKey: String) {
        log("Attempting to connect to OpenAI Realtime API")

        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime") else {
            error("Invalid WebSocket URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
        error("WebSocket delegate: Connection closed with code \(closeCode.rawValue)")
        if let reason = reason, let reasonString = String(data: reason, encoding: .utf8) {
            error("Close reason: \(reasonString)")
        }
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
        case "input_audio_buffer.speech_started":
            handleSpeechStarted()
        case "input_audio_buffer.speech_stopped":
            handleSpeechStopped()
        case "input_audio_buffer.committed":
            handleAudioBufferCommitted()
        case "response.created":
            handleResponseCreated()
        case "response.done":
            handleResponseDoneEvent(json)
        case "response.audio.delta":
            if let audioBase64 = json["delta"] as? String {
                audioManager.scheduleOutputAudioBuffer(audioBase64)
            }
        case "response.text.delta":
            handleResponseTextDelta(json)
        case "response.text.done":
            handleResponseTextDone(json)
        case "response.function_call_arguments.delta":
            debugLog(id: "functionArgsDelta", message: "⚙️ [WS] Receiving function arguments")
        case "response.function_call_arguments.done":
            handleFunctionCallArgumentsDone(json)
        case "response.output_text.delta":
            debugLog(id: "textDelta", message: "⚙️ [WS] Receiving text output")
        case "conversation.item.added":
            handleConversationItemAdded(json)
        case "response.output_audio.delta":
            debugLog(id: "audioOutputDelta", message: "⚙️ [WS] Receiving audio output")
            if let audioBase64 = json["delta"] as? String {
                audioManager.scheduleOutputAudioBuffer(audioBase64)
            }
        case "response.output_audio.done":
            log("Audio output completed")
        case "response.output_audio_transcript.delta":
            debugLog(id: "transcriptDelta", message: "📥 [WS] Transcript delta")
        case "response.output_audio_transcript.done":
            if let transcript = json["transcript"] as? String {
                log("Final transcript: \(transcript)")
            }
        case "conversation.item.done":
            handleConversationItemDone(json)
        case "session.updated":
            log("Session configuration updated successfully - 🔵 Setting API state to .connected")
            apiStateSubject.send(.connected)
            audioManager.startAudioEngine()
        case "response.output_item.added":
            handleResponseOutputItemAdded(json)
        case "response.content_part.added":
            if let part = json["part"] as? [String: Any],
               let type = part["type"] as? String {
                log("response.content_part.added: type=\(type)")
            }
        case "response.content_part.done":
            log("Response content part done")
        case "response.output_item.done":
            log("Response output item done")
        case "rate_limits.updated":
            log("Rate limits updated")
        case "conversation.item.input_audio_transcription.delta":
            debugLog(id: "inputAudioTranscriptDelta", message: "⚙️ [WS] Input audio transcription delta")
        case "conversation.item.input_audio_transcription.completed":
            log("Input audio transcription completed")
        case "response.audio_transcript.delta":
            debugLog(id: "audioTranscriptDelta", message: "⚙️ [WS] Audio transcript delta")
        case "error":
            handleErrorMessage(json)
        default:
            log("Unknown event type: \(type) - JSON: \(json)")
        }
    }

    func parseJSON(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else {
            error("Failed to convert text to data")
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            error("Failed to parse message as JSON: \(text)")
            return nil
        }

        return json
    }

    func extractMessageType(from json: [String: Any]) -> String? {
        return json["type"] as? String
    }

    func handleSessionCreated() {
        log("WebSocket connection established")
        totalBytesSent = 0
        totalBytesReceived = 0
        sendSessionUpdate()
    }

    func sendSessionUpdate() {
        let sessionUpdate: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "output_modalities": ["audio"],
                "instructions": """
                You are the ears and mouth of the computer agent. This is the first time that a person sitting in a wheelchair can use a computer just by speaking.
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
            error("WebSocket not connected - cannot send event")
            return
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: event, options: [])
            guard let text = String(data: data, encoding: .utf8) else {
                error("Failed to convert event to string")
                return
            }

            let message = URLSessionWebSocketTask.Message.string(text)
            let eventType = event["type"] as? String ?? "unknown"

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
        } catch let serializeError {
            error("Failed to serialize event: \(serializeError.localizedDescription)")
        }
    }

    func handleSpeechStarted() {
        log("Voice activity detection started - 🟡 Setting API state to .speechDetected")
        apiStateSubject.send(.speechDetected)
    }

    func handleSpeechStopped() {
        log("Voice activity detection stopped - 🟠 Setting API state to .speechStopped")
        apiStateSubject.send(.speechStopped)
        callTranscriptionDeltaFunction()
    }

    func callTranscriptionDeltaFunction() {
        queueResponseRequest { [weak self] in
            guard let self = self else { return }

            let responseCreate: [String: Any] = [
                "type": "response.create",
                "response": [
                    "tools": [
                        [
                            "type": "function",
                            "name": "transcriptionDelta",
                            "description": """
                            Whatever you heard since creating the last transcription. Please give an exact transcription of that. Don't repeat yourself if you have already transcribed something.
                            """,
                            "parameters": [
                                "type": "object",
                                "properties": [
                                    "deltaTranscription": [
                                        "type": "string",
                                        "description": "Exact verbatim transcription of what was heard since the last transcription."
                                    ]
                                ],
                                "required": ["deltaTranscription"],
                                "additionalProperties": false
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

    func queueResponseRequest(_ request: @escaping () -> Void) {
        responseQueueThread.async { [weak self] in
            guard let self = self else { return }

            if self.isResponseActive {
                self.responseRequestQueue.append(request)
                log("Response queue size: \(self.responseRequestQueue.count)")
            } else {
                log("Response queue: executing immediately")
                self.isResponseActive = true
                request()
            }
        }
    }

    func handleAudioBufferCommitted() {
        log("Audio buffer committed")
    }

    func handleResponseCreated() {
        log("Response created")
    }

    func handleResponseDoneEvent(_ json: [String: Any]) {
        log("response.done received")
        markResponseComplete()
    }

    func markResponseComplete() {
        responseQueueThread.async { [weak self] in
            self?.isResponseActive = false
            if self?.apiStateSubject.value == .processing {
                log("Response complete - 🔵 Setting API state to .connected")
                self?.apiStateSubject.send(.connected)
            }
            self?.processNextQueuedRequest()
        }
    }

    func processNextQueuedRequest() {
        responseQueueThread.async { [weak self] in
            guard let self = self else { return }

            guard !self.responseRequestQueue.isEmpty else {
                return
            }

            let nextRequest = self.responseRequestQueue.removeFirst()
            log("Response queue: processing next (remaining: \(self.responseRequestQueue.count))")
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

    func handleFunctionCallArgumentsDone(_ json: [String: Any]) {
        guard let arguments = json["arguments"] as? String else {
            error("response.function_call_arguments.done missing 'arguments' field")
            return
        }

        guard let callId = json["call_id"] as? String else {
            error("response.function_call_arguments.done missing 'call_id' field")
            return
        }

        guard let name = json["name"] as? String else {
            error("response.function_call_arguments.done missing 'name' field")
            return
        }

        log("function_call_arguments.done: call_id=\(callId), name=\(name)")

        let cleanedArguments = arguments
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\\"", with: "'")

        guard let argumentsData = cleanedArguments.data(using: .utf8) else {
            error("Failed to convert arguments to data: \(arguments)")
            return
        }

        do {
            let jsonObject = try JSONSerialization.jsonObject(with: argumentsData, options: [])

            guard let dict = jsonObject as? [String: Any],
                  let transcription = dict["deltaTranscription"] as? String else {
                error("Failed to extract deltaTranscription from arguments")
                return
            }

            let currentValue = lastPromptSubject.value
            let newValue: String

            if currentValue.isEmpty {
                newValue = transcription
            } else {
                newValue = currentValue + "\n" + transcription
            }

            lastPromptSubject.send(newValue)

            let result: [String: Any] = [
                "status": "success",
                "accumulated_transcription": newValue,
                "latest_addition": transcription
            ]

            let outputData = try JSONSerialization.data(withJSONObject: result)
            guard let outputString = String(data: outputData, encoding: .utf8) else {
                error("Failed to convert result to string")
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
            log("✅ Sent function output")

        } catch let parseError {
            error("Failed to parse arguments: \(parseError.localizedDescription)")
            error("Arguments that failed to parse: \(arguments)")
            error("Cleaned arguments: \(cleanedArguments)")
        }
    }

    func handleConversationItemAdded(_ json: [String: Any]) {
        if let item = json["item"] as? [String: Any],
           let id = item["id"] as? String,
           let type = item["type"] as? String {
            log("conversation.item.added: id=\(id), type=\(type)")

            if type == "function_call" {
                log("🟣 Setting API state to .processing (from handleConversationItemAdded)")
                apiStateSubject.send(.processing)
            }
        }
    }

    func handleConversationItemDone(_ json: [String: Any]) {
        if let item = json["item"] as? [String: Any],
           let id = item["id"] as? String,
           let status = item["status"] as? String {
            log("conversation.item.done: id=\(id), status=\(status)")
        }
    }

    func handleResponseOutputItemAdded(_ json: [String: Any]) {
        guard let item = json["item"] as? [String: Any] else {
            return
        }

        guard let itemType = item["type"] as? String else {
            return
        }

        if itemType == "function_call" {
            guard let callId = item["call_id"] as? String,
                  let name = item["name"] as? String,
                  let status = item["status"] as? String else {
                return
            }

            currentFunctionCallId = callId
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
        error(errorMessage)
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

    func requestAudioResponse(for prompt: String) {
        queueResponseRequest { [weak self] in
            guard let self = self else { return }

            let responseEvent: [String: Any] = [
                "type": "response.create",
                "response": [
                    "instructions": """
                    This is crucial for eye health, so the user doesn't have to check the screen to verify the prompt is correct. The user must be able to verify that the prompt reflects what they said, only by listening.

                    You are NOT answering questions. You are ONLY confirming what prompt is being forwarded to the command line agent. Just read back keywords from the prompt, nothing else. Do NOT try to be helpful or provide answers.

                    You're just helping the user to not look at the screen after sending their prompt.

                    DO NOT BLABBER. This is NOT a conversation. Give a VERY VERY short summary.
                    DO NOT start by saying "Summary".
                    DO NOT end by adding anything else.

                    ONE SENTENCE WITH A MAXIMUM OF FIVE WORDS. ONLY KEYWORDS.

                    Summarize this prompt in 5 words or less:

                    \(prompt)
                    """,
                    "output_modalities": ["audio"]
                ]
            ]
            self.send(event: responseEvent)
            log("Requesting one-word audio acknowledgment")
        }
    }

    func acknowledgeSuccessfulPromptInjection() {
        let promptToSummarize = lastPromptSubject.value
        lastPromptSubject.send("")
        log("🧹 Cleared accumulated prompts after successful prompt injection and creating voice response")

        requestAudioResponse(for: promptToSummarize)
    }

    func acknowledgeSuccessfulInterruptExecution() {
        log("🛑 Interrupt successfully executed - keeping accumulated prompts (interrupt doesn't clear them)")
    }

    func clearAccumulatedPrompts() {
        lastPromptSubject.send("")
        log("🗑️ Manually cleared accumulated prompts")
    }


    func disconnect() {
        log("Disconnecting WebSocket - ⚫ Setting API state to .disconnected")
        apiStateSubject.send(.disconnected)
        audioManager.stopAudioEngine()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }

    deinit {
        audioManager.stopAudioEngine()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        log("realtimeAPI deallocated")
    }
}
