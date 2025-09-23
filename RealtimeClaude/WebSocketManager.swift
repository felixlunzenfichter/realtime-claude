
import Foundation
@preconcurrency import AVFoundation

class WebSocketManager: NSObject, @unchecked Sendable {
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let apiKey = "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"
    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?

    override init() {
        super.init()
        log("WebSocketManager initialized")

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60.0
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
                self.connect()
            } else {
                error("Microphone permission denied - cannot proceed")
            }
        }
    }

    func connect() {
        log("Attempting to connect to OpenAI Realtime API")

        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime") else {
            error("Invalid WebSocket URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
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
                    self.handleDataMessage(data)
                case .string(let text):
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
            error("Binary data received: \(data.count) bytes - cannot process")
        }
    }

    func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else {
            error("Failed to convert text to data")
            return
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            error("Failed to parse message as JSON: \(text)")
            return
        }

        guard let type = json["type"] as? String else {
            error("Message missing 'type' field: \(text)")
            return
        }

        switch type {
        case "session.created":
            log("WebSocket connection established")
            self.sendSessionUpdate()
            self.startAudioCapture()
        case "input_audio_buffer.speech_started":
            log("Voice activity detection started")
        case "input_audio_buffer.speech_stopped":
            log("Voice activity detection stopped")
        case "input_audio_buffer.committed":
            log("Audio buffer committed")
        case "response.created":
            log("Response created")
        case "response.done":
            log("Response completed")
        case "session.updated", "conversation.item.created", "response.output_item.added", "response.content_part.added", "response.audio.done", "response.audio_transcript.done", "response.content_part.done", "response.output_item.done", "rate_limits.updated", "conversation.item.input_audio_transcription.delta", "conversation.item.input_audio_transcription.completed", "response.audio.delta", "response.audio_transcript.delta":
            break
        case "error":
            if let errorInfo = json["error"] as? [String: Any] {
                let errorType = errorInfo["type"] as? String ?? "unknown"
                let errorMessage = errorInfo["message"] as? String ?? "no message"
                error("Error type: \(errorType), message: \(errorMessage)")
            } else {
                error("Full error event: \(json)")
            }
        default:
            log("Unknown event type: \(type) - JSON: \(json)")
        }
    }

    func handleError(_ connectionError: Error) {
        let nsError = connectionError as NSError

        switch nsError.code {
        case 57:
            error("WebSocket disconnected: Socket not connected")
        case 54:
            error("WebSocket disconnected: Connection reset by peer")
        default:
            error("WebSocket error: \(connectionError.localizedDescription)")
        }
    }

    func sendSessionUpdate() {
        let sessionUpdate: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["text", "audio"],
                "instructions": "You are a helpful assistant.",
                "voice": "alloy",
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "input_audio_transcription": [
                    "model": "whisper-1"
                ],
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 200
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
        audioEngine = AVAudioEngine()

        guard let audioEngine = audioEngine else {
            error("Failed to create audio engine")
            return
        }

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let outputFormat = createOutputFormat() else {
            error("Failed to create output audio format")
            return
        }

        audioConverter = AVAudioConverter(from: inputFormat, to: outputFormat)

        if audioConverter == nil {
            error("Failed to create audio converter")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }
    }

    func createOutputFormat() -> AVAudioFormat? {
        return AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false)
    }

    func startAudioEngine() {
        guard let audioEngine = audioEngine else {
            error("Audio engine not initialized")
            return
        }

        do {
            try audioEngine.start()
            log("Audio engine started successfully")
        } catch let startError {
            error("Failed to start audio engine: \(startError.localizedDescription)")
        }
    }

    func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = audioConverter else {
            error("Audio converter not available")
            return
        }

        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * 24000.0 / buffer.format.sampleRate)

        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: outputFrameCapacity) else {
            error("Failed to create converted buffer")
            return
        }

        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        var converterError: NSError? = nil
        let status = converter.convert(to: convertedBuffer, error: &converterError, withInputFrom: inputBlock)

        if let converterError = converterError {
            error("Audio conversion failed: \(converterError.localizedDescription)")
            return
        }

        if status == .haveData {
            sendAudioData(convertedBuffer)
        }
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
    }

    deinit {
        stopAudioCapture()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
    }
}

extension WebSocketManager: URLSessionWebSocketDelegate {
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

