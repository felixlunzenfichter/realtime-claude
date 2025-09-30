
import Foundation
@preconcurrency import AVFoundation
import Combine

protocol RealtimeAPIProtocol: Sendable {
    var microphoneEnabledSubject: CurrentValueSubject<Bool, Never> { get }
    var playingAudioSubject: CurrentValueSubject<Bool, Never> { get }
    var lastPromptSubject: CurrentValueSubject<String, Never> { get }

    func connect(apiKey: String)
    func enableMicrophone()
    func disableMicrophone()
    func enablePlayback()
    func disablePlayback()
}

class RealtimeAPI: NSObject, @unchecked Sendable, RealtimeAPIProtocol {
    static let shared: RealtimeAPIProtocol = RealtimeAPI()
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var apiKey = ""
    private var playbackEnabled = false
    let OPENAI_AUDIO_FORMAT = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false)!
    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
    private var responsePlayerNode: AVAudioPlayerNode?
    let microphoneEnabledSubject = CurrentValueSubject<Bool, Never>(false)
    let playingAudioSubject = CurrentValueSubject<Bool, Never>(false)
    let lastPromptSubject = CurrentValueSubject<String, Never>("")
    private var totalBytesSent: Int = 0
    private var totalBytesReceived: Int = 0

    override init() {
        super.init()
        log("WebSocketManager initialized")

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = 600.0

        self.urlSession = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: OperationQueue.main
        )

        requestMicrophonePermission()
    }

    func requestMicrophonePermission() {
        log("Requesting microphone permission...")
        Task {
            let granted = await AVAudioApplication.requestRecordPermission()
            if granted {
                log("Microphone permission granted")
            } else {
                error("Microphone permission denied - cannot proceed")
            }
        }
    }

    func connect(apiKey: String) {
        log("Attempting to connect to OpenAI Realtime API")
        self.apiKey = apiKey

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

        // Update total bytes received
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
            handleResponseAudioDelta(json)
        case "response.text.delta":
            handleResponseTextDelta(json)
        case "response.text.done":
            handleResponseTextDone(json)
        case "response.function_call_arguments.done":
            handleFunctionCallArgumentsDone(json)
        case "response.function_call_arguments.delta":
            debugLog(id: "functionArgsDelta", message: "⚙️ [WS] Receiving function arguments")
        case "response.output_text.delta":
            debugLog(id: "textDelta", message: "⚙️ [WS] Receiving text output")
        case "response.output_text.done":
            handleOutputTextDone(json)
        case "conversation.item.added":
            debugLog(id: "conversationItem", message: "✅ [WS] Conversation item added")
        case "response.output_audio.delta":
            // This is the actual audio data event (different from response.audio.delta)
            if let audioBase64 = json["delta"] as? String {
                scheduleResponseAudio(audioBase64)
            }
        case "response.output_audio.done":
            log("Audio output completed")
        case "response.output_audio_transcript.delta":
            if let delta = json["delta"] as? String {
                debugLog(id: "transcriptDelta", message: "📥 [WS] Transcript delta: \(delta)")
            }
        case "response.output_audio_transcript.done":
            if let transcript = json["transcript"] as? String {
                log("Final transcript: \(transcript)")
            }
        case "conversation.item.done":
            debugLog(id: "conversationComplete", message: "✅ [WS] Conversation item completed")
        case "session.updated", "conversation.item.created", "response.output_item.added", "response.content_part.added", "response.audio.done", "response.audio_transcript.done", "response.content_part.done", "response.output_item.done", "rate_limits.updated", "conversation.item.input_audio_transcription.delta", "conversation.item.input_audio_transcription.completed", "response.audio_transcript.delta", "response.function_call_arguments.delta":
            break
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
        startAudioCapture()
    }

    func handleSpeechStarted() {
        log("Voice activity detection started")
    }

    func handleSpeechStopped() {
        log("Voice activity detection stopped")
        // Request the model to extract the user's speech and call createPrompt function
        callCreatePromptFunction()
    }

    func handleAudioBufferCommitted() {
        log("Audio buffer committed")
    }

    func handleResponseCreated() {
        log("Response created")
    }

    func handleResponseDone() {
        log("Response completed")
    }

    func handleResponseDoneEvent(_ json: [String: Any]) {
        log("Response done event received: \(json)")
    }

    func handleResponseAudioDelta(_ json: [String: Any]) {
        if let audioBase64 = json["delta"] as? String {
            scheduleResponseAudio(audioBase64)
        }
    }

    func handleResponseTextDelta(_ json: [String: Any]) {
        if let delta = json["delta"] as? String {
            debugLog(id: "textDelta", message: "📥 [WS] Text delta: \(delta)")
        }
    }

    func handleResponseTextDone(_ json: [String: Any]) {
        log("Response text done received: \(json)")
    }

    func handleOutputTextDone(_ json: [String: Any]) {
        guard let text = json["text"] as? String else {
            error("response.output_text.done missing 'text' field")
            return
        }

        // Try to extract prompt from JSON text output
        if let textData = text.data(using: .utf8),
           let jsonObject = try? JSONSerialization.jsonObject(with: textData) as? [String: Any],
           let prompt = jsonObject["prompt"] as? String {
            log("Extracted prompt from text output: \(prompt)")

            // Update the UI with the prompt directly (no formatting)
            lastPromptSubject.send(prompt)
        } else {
            error("Failed to extract prompt from text output: \(text)")
        }
    }

    func handleFunctionCallArgumentsDone(_ json: [String: Any]) {
        log("Function call arguments done received: \(json)")
    }

    func callCreatePromptFunction() {
        let responseCreate: [String: Any] = [
            "type": "response.create",
            "response": [
                "instructions": """
                The user just spoke. Extract what they said and call createPrompt function.
                Format as numbered task list:
                1. First task
                2. Second task
                3. Third task

                Keep it concise and action-oriented. Remove filler words.
                """,
                "tool_choice": [
                    "type": "function",
                    "name": "createPrompt"
                ],
                "output_modalities": ["text"]
            ]
        ]

        send(event: responseCreate)
        log("Requesting createPrompt function call after speech stopped")
    }

    func sendFunctionCallResult(callId: String, result: [String: Any]) {
        guard !callId.isEmpty else {
            error("Cannot send function call result with empty call_id")
            return
        }

        do {
            let outputData = try JSONSerialization.data(withJSONObject: result)
            guard let outputString = String(data: outputData, encoding: .utf8) else {
                error("Failed to convert result to string for call_id: \(callId)")
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
            log("Sent function call result for call_id: \(callId)")
        } catch let serializeError {
            error("Failed to serialize function call result: \(serializeError.localizedDescription), call_id: \(callId)")
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

    func sendSessionUpdate() {
        let sessionUpdate: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "output_modalities": ["audio"],
                "instructions": "You are a helpful assistant.",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24000
                        ],
                        "turn_detection": [
                            "type": "server_vad",
                            "threshold": 0.5,
                            "prefix_padding_ms": 300,
                            "silence_duration_ms": 200,
                            "create_response": false,
                            "interrupt_response": true
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
                ],
                "tools": [
                    [
                        "type": "function",
                        "name": "createPrompt",
                        "description": "Create prompt formatted as numbered task list",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "prompt": [
                                    "type": "string",
                                    "description": "User's request formatted as numbered task list with no filler words"
                                ]
                            ],
                            "required": ["prompt"],
                            "additionalProperties": false
                        ]
                    ]
                ],
                "tool_choice": "none"
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

            // Track size for all events
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

    func startAudioCapture() {
        setupAudioEngine()
        startAudioEngine()
    }

    func setupAudioEngine() {
        audioEngine = createAndConfigureAudioEngine()

        guard let audioEngine = audioEngine else {
            error("Failed to create audio engine")
            return
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        setupAudioConverter(from: inputFormat, to: OPENAI_AUDIO_FORMAT)
        setupResponsePlayerNode(in: audioEngine, format: OPENAI_AUDIO_FORMAT)
    }

    func createAndConfigureAudioEngine() -> AVAudioEngine {
        return AVAudioEngine()
    }

    func setupAudioConverter(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
        audioConverter = AVAudioConverter(from: inputFormat, to: outputFormat)

        if audioConverter == nil {
            error("Failed to create audio converter")
        }
    }

    func setupResponsePlayerNode(in audioEngine: AVAudioEngine, format: AVAudioFormat) {
        responsePlayerNode = AVAudioPlayerNode()

        guard let playerNode = responsePlayerNode else {
            error("Failed to create response player node")
            return
        }

        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
    }

    func installAudioTap() {
        guard let audioEngine = audioEngine else {
            error("Audio engine not initialized")
            return
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }

            if self.microphoneEnabledSubject.value {
                self.processInputAudioBuffer(buffer)
            } else {
                debugLog(id: "inputAudio", message: "⛔ [Audio] Microphone disabled, ignoring buffer")
            }
        }
        
        self.microphoneEnabledSubject.send(true)
        log("Audio tap installed")
    }

    func uninstallAudioTap() {
        guard let audioEngine = audioEngine else {
            error("Audio engine not initialized")
            return
        }

        audioEngine.inputNode.removeTap(onBus: 0)
        
        microphoneEnabledSubject.send(false)
        log("Audio tap uninstalled")
    }


    func startAudioEngine() {
        guard let audioEngine = audioEngine else {
            error("Audio engine not initialized")
            return
        }

        do {
            try audioEngine.start()
            log("Audio engine started successfully")

            guard let playerNode = responsePlayerNode else {
                error("Response player node not initialized")
                return
            }

            playerNode.play()
            log("Response player node started")
        } catch let startError {
            error("Failed to start audio engine: \(startError.localizedDescription)")
        }
    }

    func processInputAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // Microphone check already done in installAudioTap, no need to check again
        guard let convertedBuffer = convertAudioBuffer(buffer) else {
            return
        }

        sendAudioData(convertedBuffer)
    }

    func convertAudioBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter = audioConverter else {
            error("Audio converter not available")
            return nil
        }

        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * 24000.0 / buffer.format.sampleRate)

        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: outputFrameCapacity) else {
            error("Failed to create converted buffer")
            return nil
        }

        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        var converterError: NSError? = nil
        let status = converter.convert(to: convertedBuffer, error: &converterError, withInputFrom: inputBlock)

        if let converterError = converterError {
            error("Audio conversion failed: \(converterError.localizedDescription)")
            return nil
        }

        return status == .haveData ? convertedBuffer : nil
    }

    func sendAudioData(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.int16ChannelData?[0] else {
            error("Failed to get channel data")
            return
        }

        let frameLength = Int(buffer.frameLength)
        let data = Data(bytes: channelData, count: frameLength * MemoryLayout<Int16>.size)
        let base64Audio = data.base64EncodedString()

        let audioEvent: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64Audio
        ]

        send(event: audioEvent)
    }

    func scheduleResponseAudio(_ audioBase64: String) {
        if !playingAudioSubject.value {
            debugLog(id: "scheduleAudio", message: "⛔ [Audio] Playback disabled, skipping audio")
            return
        }

        guard let playerNode = responsePlayerNode else {
            error("Response player node not available")
            return
        }


        guard let audioData = Data(base64Encoded: audioBase64) else {
            error("Failed to decode response audio data")
            return
        }

        guard let buffer = createPCMBuffer(from: audioData, format: OPENAI_AUDIO_FORMAT) else {
            error("Failed to create PCM buffer from response audio")
            return
        }

        playerNode.scheduleBuffer(buffer) { [weak self] in
            guard let self = self else {
                error("RealtimeAPI deallocated during audio playback")
                return
            }
        }
    }

    func createPCMBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameLength = UInt32(data.count / MemoryLayout<Int16>.size)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }

        buffer.frameLength = frameLength

        let audioBuffer = buffer.int16ChannelData![0]
        data.withUnsafeBytes { bytes in
            audioBuffer.initialize(from: bytes.bindMemory(to: Int16.self).baseAddress!, count: Int(frameLength))
        }

        return buffer
    }

    func enableMicrophone() {
        if microphoneEnabledSubject.value {
            debugLog(id: "enableMicrophone", message: "⚠️ [Audio] Microphone already enabled, ignoring")
            return
        }
        stopPlayback()
        installAudioTap()
        log("Microphone enabled")
    }

    func stopPlayback() {
        playingAudioSubject.send(false)
        responsePlayerNode?.stop()
    }

    func disableMicrophone() {
        uninstallAudioTap()

        // Send prompt to Claude Code if we have one
        let currentPrompt = lastPromptSubject.value
        if !currentPrompt.isEmpty {
            log("Sending prompt to Claude Code: \(currentPrompt)")
            Logger.shared.sendPromptToMac(currentPrompt, category: "general")

            // Clear the prompt after sending
            lastPromptSubject.send("")
        }

        if playbackEnabled {
            responsePlayerNode?.play()
            playingAudioSubject.send(true)
            createResponse()
        }
        log("Microphone disabled")
    }

    func enablePlayback() {
        playbackEnabled = true
        log("Playback enabled")
    }

    func disablePlayback() {
        playbackEnabled = false
        responsePlayerNode?.stop()
        log("Playback disabled")
    }

    func commitAudioBuffer() {
        let commitEvent: [String: Any] = [
            "type": "input_audio_buffer.commit"
        ]
        send(event: commitEvent)
        log("Audio buffer committed")
    }

    func createResponse() {
        let responseEvent: [String: Any] = [
            "type": "response.create"
        ]
        send(event: responseEvent)
        log("Response requested")
    }

    func disconnect() {
        log("Disconnecting WebSocket...")
        stopAudioCapture()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }

    func stopAudioCapture() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        audioConverter = nil
        log("Audio capture stopped")
    }

    deinit {
        stopAudioCapture()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        log("RealtimeAPI deallocated")
    }
}

extension RealtimeAPI: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        log("WebSocket delegate: Connection opened")
        if let `protocol` = `protocol` {
            log("Using protocol: \(`protocol`)")
        }

        self.receiveMessage()
    }

    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                                reason: Data?) {
        error("WebSocket delegate: Connection closed with code \(closeCode.rawValue)")
        if let reason = reason, let reasonString = String(data: reason, encoding: .utf8) {
            error("Close reason: \(reasonString)")
        }
    }
}

