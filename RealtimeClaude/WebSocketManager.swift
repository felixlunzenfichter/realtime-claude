
import Foundation
import AVFoundation

class WebSocketManager: NSObject, @unchecked Sendable {
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let apiKey = "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"

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

        log("Event received: \(type)")

        if type == "session.created" {
            log("WebSocket connection established")
            self.sendSessionUpdate()
        } else if type == "error" {
            if let errorInfo = json["error"] as? [String: Any] {
                let errorType = errorInfo["type"] as? String ?? "unknown"
                let errorMessage = errorInfo["message"] as? String ?? "no message"
                error("Error type: \(errorType), message: \(errorMessage)")
            } else {
                error("Full error event: \(json)")
            }
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

            log("Sending event: \(eventType)")

            webSocketTask.send(message) { sendError in
                if let sendError = sendError {
                    error("Failed to send \(eventType): \(sendError.localizedDescription)")
                } else {
                    log("Successfully sent: \(eventType)")
                }
            }
        } catch let serializeError {
            error("Failed to serialize event: \(serializeError.localizedDescription)")
        }
    }

    func disconnect() {
        log("Disconnecting WebSocket...")
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }

    deinit {
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

