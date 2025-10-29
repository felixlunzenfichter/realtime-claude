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
        case "session.updated":
            handleSessionUpdated()
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
            handleResponseOutputAudioDone()
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
        log("WebSocket connection established")
        sendSessionUpdate()
    }

    func handleSessionUpdated() {
        log("Session configuration updated successfully - 🔵 Setting API state to .connected")
        apiStateSubject.send(.connected)
        audioManager.startAudioEngine()
    }

    func sendSessionUpdate() {
        let sessionUpdate: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "output_modalities": ["audio"],
                "instructions": """
                You are the ears and mouth of the computer agent. You are NOT the brain.
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
            error("Cannot send event: WebSocket task is nil")
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
        if isResponseActive {
            log("response.done: Response still active, marking complete (audio response)")
            markResponseComplete()
        } else {
            log("response.done: Response already completed (was function call)")
        }
    }

    func markResponseComplete() {
        log("✅ markResponseComplete() called")
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
            error("Missing or invalid 'arguments' field in function call")
            return
        }

        guard let callId = json["call_id"] as? String else {
            error("Missing or invalid 'call_id' field in function call")
            return
        }

        guard let name = json["name"] as? String else {
            error("Missing or invalid 'name' field in function call")
            return
        }

        log("function_call_arguments.done: call_id=\(callId), name=\(name)")

        guard let argumentsData = arguments.data(using: .utf8) else {
            error("Failed to convert arguments to UTF-8 data. Raw arguments: \(arguments)")
            return
        }

        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: argumentsData, options: [])
        } catch let parseError {
            error("Failed to parse function arguments as JSON: \(parseError.localizedDescription). Raw arguments: \(arguments)")
            return
        }

        guard let dict = jsonObject as? [String: Any] else {
            error("Function arguments not a dictionary. Raw arguments: \(arguments)")
            return
        }

        let transcription: String

        if let deltaTranscription = dict["deltaTranscription"] as? String {
            transcription = deltaTranscription
        } else if let firstKey = dict.keys.first,
                  let firstValue = dict[firstKey] as? String {
            transcription = firstValue
        } else {
            error("No usable value found in function arguments. Name: \(name), Raw arguments: \(arguments)")
            return
        }

        let filteredTranscription = transcription
            .replacingOccurrences(of: "\u{201C}", with: "")
            .replacingOccurrences(of: "\u{201D}", with: "")
            .replacingOccurrences(of: "\u{2018}", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")

        if filteredTranscription != transcription {
            debugLog(id: "transcriptionFiltered", message: "Filtered transcription: \(filteredTranscription)")
        }

        let currentValue = lastPromptSubject.value
        let newValue: String

        if currentValue.isEmpty {
            newValue = filteredTranscription
        } else {
            newValue = currentValue + "\n" + filteredTranscription
        }

        lastPromptSubject.send(newValue)

        let result: [String: Any] = [
            "status": "success",
            "accumulated_transcription": newValue,
            "latest_addition": transcription
        ]

        let outputData: Data
        do {
            outputData = try JSONSerialization.data(withJSONObject: result)
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
        log("✅ Sent function output")
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

            if type == "function_call_output" {
                markResponseComplete()
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

    func handleResponseAudioDelta(_ json: [String: Any]) {
        guard let audioBase64 = json["delta"] as? String else {
            error("Missing or invalid 'delta' field in response.audio.delta")
            return
        }
        audioManager.scheduleOutputAudioBuffer(audioBase64)
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
        audioManager.scheduleOutputAudioBuffer(audioBase64)
    }

    func handleResponseOutputAudioDone() {
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
                    "instructions": "The following transcription has been sent to the computer agent for execution: [START TRANSCRIPTION] \(prompt) [STOP TRANSCRIPTION]. To confirm that the transcription is correct without looking at the screen, provide an extremely short one-sentence summary. For example, if prompted with 'push this', respond with 'pushing the changes'.",
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
