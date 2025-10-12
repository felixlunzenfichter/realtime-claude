/*
# REFACTORING DOCUMENT: RealtimeAPI.swift

## Current State: ✅ PROPERLY ORDERED

### Protocol: RealtimeAPIProtocol (Sendable)

#### Properties:
- microphoneEnabledSubject: CurrentValueSubject<Bool, Never> (public, var)
- playingAudioSubject: CurrentValueSubject<Bool, Never> (public, var)
- lastPromptSubject: CurrentValueSubject<String, Never> (public, var)
- voiceActivityStartedSubject: PassthroughSubject<Date, Never> (public, var)
- voiceActivityStoppedSubject: PassthroughSubject<Date, Never> (public, var)
- functionExecutionStartedSubject: PassthroughSubject<Date, Never> (public, var)

#### Functions:
Line 283: connect(apiKey:) → (not documented in protocol)
Line 284: enableMicrophone() → (not documented in protocol)
Line 285: disableMicrophone() → (not documented in protocol)
Line 286: enablePlayback() → (not documented in protocol)
Line 287: disablePlayback() → (not documented in protocol)
Line 288: realTimeApiAcknowledgeSuccessful() → (not documented in protocol)
Line 289: clearAccumulatedPrompts() → (not documented in protocol)

### Global Variables:
Line 22: realtimeAPI: RealtimeAPIProtocol (nonisolated unsafe, let)

### Class: RealtimeAPI (NSObject, URLSessionWebSocketDelegate, @unchecked Sendable, RealtimeAPIProtocol, private)

#### Constants:
- OPENAI_AUDIO_FORMAT: AVAudioFormat (public, let) = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false)!
- apiStateSubject: CurrentValueSubject<APIState, Never> (public, let) = CurrentValueSubject(.disconnected) → sends states in various handlers
- lastPromptSubject: CurrentValueSubject<String, Never> (public, let) = CurrentValueSubject("") → sends: lastPromptSubject.send(newValue) in handleFunctionCallArgumentsDone
- microphoneEnabledSubject: CurrentValueSubject<Bool, Never> (public, let) = CurrentValueSubject(false) → sends: microphoneEnabledSubject.send(true) in installAudioTap, microphoneEnabledSubject.send(false) in uninstallAudioTap
- playingAudioSubject: CurrentValueSubject<Bool, Never> (public, let) = CurrentValueSubject(false) → sends: playingAudioSubject.send(true/false) in scheduleResponseAudio buffer completion
- audioEngine: AVAudioEngine (private, let) = AVAudioEngine()
- audioConverter: AVAudioConverter (private, let) = AVAudioConverter(from: inputFormat, to: OPENAI_AUDIO_FORMAT)!
- responsePlayerNode: AVAudioPlayerNode (private, let) = AVAudioPlayerNode()
- responseQueueThread: DispatchQueue (private, let) = DispatchQueue(label: "com.realtimeapi.responsequeue", qos: .userInitiated)

#### Properties:
- apiKey: String (private, var) = "" → mutated in: connect(= apiKey parameter)
- currentFunctionCallId: String? (private, var) = nil → mutated in: handleResponseOutputItemAdded(= callId from JSON)
- isResponseActive: Bool (private, var) = false → mutated in: queueResponseRequest(= true), markResponseComplete(= false), processNextQueuedRequest(= true)
- playbackEnabled: Bool (private, var) = true → mutated in: enablePlayback(= true), disablePlayback(= false)
- responseRequestQueue: [() -> Void] (private, var) = [] → mutated in: queueResponseRequest(append request), processNextQueuedRequest(removeFirst)
- scheduledBufferCount: Int (private, var) = 0 → mutated in: scheduleResponseAudio(+= 1), buffer completion(-= 1)
- totalBytesReceived: Int (private, var) = 0 → mutated in: handleSessionCreated(= 0), handleTextMessage(+= messageSize)
- totalBytesSent: Int (private, var) = 0 → mutated in: handleSessionCreated(= 0), send(+= data.count)
- urlSession: URLSession? (private, var) = nil → mutated in: init(= URLSession(...))
- webSocketTask: URLSessionWebSocketTask? (private, var) = nil → mutated in: connect(= session.webSocketTask()), disconnect(= nil)

#### Functions:
Line 319: init() → AVAudioEngine.init(), AVAudioConverter.init(), AVAudioPlayerNode.init(), URLSession.init(), requestMicrophonePermission()
  → log: "WebSocketManager initialized"

Line 344: requestMicrophonePermission() → AVAudioApplication.requestRecordPermission()
  → log: "Requesting microphone permission..."
  → log: "Microphone permission granted"
  → error: "Microphone permission denied - cannot proceed"

Line 356: connect(apiKey:) → URL.init(), URLRequest.init(), urlSession.webSocketTask(), webSocketTask.resume()
  → log: "Attempting to connect to OpenAI Realtime API"
  → log: "Creating WebSocket task..."
  → log: "Starting WebSocket connection..."
  → log: "WebSocket connection initiated - waiting for delegate callback"
  → error: "Invalid WebSocket URL"
  → error: "URLSession not initialized"

Line 385: urlSession(_:webSocketTask:didOpenWithProtocol:) → receiveMessage()
  → log: "WebSocket delegate: Connection opened"
  → log: "Using protocol: \(`protocol`)"

Line 396: urlSession(_:webSocketTask:didCloseWith:reason:) | (leaf)
  → error: "WebSocket delegate: Connection closed with code \(closeCode.rawValue)"
  → error: "Close reason: \(reasonString)"

Line 406: receiveMessage() → webSocketTask.receive(), handleDataMessage(), handleTextMessage(), receiveMessage(), handleError()
  → debug: "📥 [WS] Received data message"
  → debug: "📥 [WS] Received text message"
  → error: "Received unknown message type"
  → error: "WebSocketManager deallocated during receive"

Line 434: handleDataMessage(_:) → String.init(), handleTextMessage()
  → error: "Binary data received: \(data.count.formattedBytes) - cannot process"

Line 442: handleTextMessage(_:) → parseJSON(), extractMessageType(), handleSessionCreated(), handleSpeechStarted(), handleSpeechStopped(), handleAudioBufferCommitted(), handleResponseCreated(), handleResponseDoneEvent(), handleResponseAudioDelta(), handleResponseTextDelta(), handleResponseTextDone(), handleFunctionCallArgumentsDone(), scheduleResponseAudio(), handleConversationItemAdded(), handleConversationItemDone(), handleResponseOutputItemAdded(), handleErrorMessage()
  → debug: "📥 [WS] Received \(type): \(messageSize.formattedBytes) (total: \(totalBytesReceived.formattedBytes))"
  → debug: "⚙️ [WS] Receiving function arguments"
  → debug: "⚙️ [WS] Receiving text output"
  → debug: "⚙️ [WS] Receiving audio output"
  → debug: "📥 [WS] Transcript delta"
  → debug: "⚙️ [WS] Input audio transcription delta"
  → debug: "⚙️ [WS] Audio transcript delta"
  → log: "Audio output completed"
  → log: "Final transcript: \(transcript)"
  → log: "Session updated"
  → log: "response.content_part.added: type=\(type)"
  → log: "Response content part done"
  → log: "Response output item done"
  → log: "Rate limits updated"
  → log: "Input audio transcription completed"
  → log: "Unknown event type: \(type) - JSON: \(json)"
  → error: "Message missing 'type' field: \(text)"

Line 528: parseJSON(from:) → String.data(), JSONSerialization.jsonObject()
  → error: "Failed to convert text to data"
  → error: "Failed to parse message as JSON: \(text)"

Line 542: extractMessageType(from:) | (leaf)

Line 546: handleSessionCreated() → sendSessionUpdate()
  → log: "WebSocket connection established"

Line 554: sendSessionUpdate() → send()

Line 591: send(event:) → JSONSerialization.data(), String.init(), URLSessionWebSocketTask.Message.string(), webSocketTask.send()
  → log: "Sending event: \(eventType)"
  → log: "Successfully sent: \(eventType)"
  → debug: "📤 [WS] Sending \(eventType): \(data.count.formattedBytes) (total: \(totalBytesSent.formattedBytes))"
  → error: "WebSocket not connected - cannot send event"
  → error: "Failed to convert event to string"
  → error: "Failed to send \(eventType): \(sendError.localizedDescription)"
  → error: "Failed to serialize event: \(serializeError.localizedDescription)"

Line 627: startAudioCapture() → startAudioEngine()

Line 631: startAudioEngine() → audioEngine.start()
  → log: "Audio engine started successfully"
  → error: "Failed to start audio engine: \(startError.localizedDescription)"

Line 643: handleSpeechStarted() → apiStateSubject.send(.speechDetected)
  → log: "Voice activity detection started"

Line 648: handleSpeechStopped() → apiStateSubject.send(.speechStopped), callCreatePromptFunction()
  → log: "Voice activity detection stopped"

Line 653: callCreatePromptFunction() → queueResponseRequest(), send()
  → log: "Requesting createPrompt function call after speech stopped"

Line 695: queueResponseRequest(_:) → responseQueueThread.async()
  → log: "Response queue size: \(self.responseRequestQueue.count)"
  → log: "Response queue: executing immediately"

Line 710: handleAudioBufferCommitted() | (leaf)
  → log: "Audio buffer committed"

Line 714: handleResponseCreated() | (leaf)
  → log: "Response created"

Line 718: handleResponseDoneEvent(_:) → markResponseComplete()
  → log: "response.done received"

Line 723: markResponseComplete() → responseQueueThread.async(), processNextQueuedRequest()

Line 730: processNextQueuedRequest() → responseQueueThread.async()
  → log: "Response queue: processing next (remaining: \(self.responseRequestQueue.count))"

Line 745: handleResponseAudioDelta(_:) → scheduleResponseAudio()

Line 751: scheduleResponseAudio(_:) → Data.init(), createPCMBuffer(), responsePlayerNode.scheduleBuffer(), playingAudioSubject.send()
  → debug: "⛔ [Audio] Playback disabled, skipping audio"
  → debug: "🎵 [Audio] All buffers finished playing"
  → log: "Stopped playing response"
  → log: "Started playing response"
  → error: "Failed to decode response audio data"
  → error: "Failed to create PCM buffer from response audio"
  → error: "realtimeAPI deallocated during audio playback"

Line 790: createPCMBuffer(from:format:) → AVAudioPCMBuffer.init()

Line 807: handleResponseTextDelta(_:) | (leaf)
  → debug: "📥 [WS] Text delta: \(delta)"

Line 813: handleResponseTextDone(_:) | (leaf)
  → log: "response.text.done event received"

Line 817: handleFunctionCallArgumentsDone(_:) → String.trimmingCharacters(), String.replacingOccurrences(), String.data(), JSONSerialization.jsonObject(), lastPromptSubject.send(), JSONSerialization.data(), String.init(), send()
  → log: "function_call_arguments.done: call_id=\(callId), name=\(name)"
  → log: "📝 Added prompt: \(prompt)"
  → log: "📝 Accumulated: \(newValue)"
  → log: "✅ Sent function output"
  → error: "response.function_call_arguments.done missing 'arguments' field"
  → error: "response.function_call_arguments.done missing 'call_id' field"
  → error: "response.function_call_arguments.done missing 'name' field"
  → error: "Failed to convert arguments to data: \(arguments)"
  → error: "Failed to extract prompt from arguments"
  → error: "Failed to convert result to string"
  → error: "Failed to parse arguments: \(parseError.localizedDescription)"
  → error: "Arguments that failed to parse: \(arguments)"
  → error: "Cleaned arguments: \(cleanedArguments)"

Line 893: handleConversationItemAdded(_:) → apiStateSubject.send(.processing)
  → log: "conversation.item.added: id=\(id), type=\(type)"

Line 904: handleConversationItemDone(_:) | (leaf)
  → log: "conversation.item.done: id=\(id), status=\(status)"

Line 912: handleResponseOutputItemAdded(_:) | (leaf)
  → log: "response.output_item.added: \(name) (\(status))"

Line 933: handleErrorMessage(_:) | (leaf)
  → error: "Error type: \(errorType), message: \(errorMessage)"
  → error: "Full error event: \(json)"

Line 943: handleError(_:) → formatConnectionError()
  → error: errorMessage

Line 949: formatConnectionError(_:) | (leaf)

Line 960: enableMicrophone() → stopPlayback(), installAudioTap()
  → debug: "⚠️ [Audio] Microphone already enabled, ignoring"
  → log: "Microphone enabled"

Line 970: stopPlayback() → responsePlayerNode.stop()

Line 974: installAudioTap() → audioEngine.inputNode.installTap(), processInputAudioBuffer(), microphoneEnabledSubject.send()
  → debug: "⛔ [Audio] Microphone disabled, ignoring buffer"
  → log: "Audio tap installed"

Line 992: processInputAudioBuffer(_:) → convertAudioBuffer(), sendAudioData()

Line 1000: convertAudioBuffer(_:) → AVAudioPCMBuffer.init(), audioConverter.convert()
  → error: "Failed to create converted buffer"
  → error: "Audio conversion failed: \(converterError.localizedDescription)"

Line 1024: sendAudioData(_:) → Data.init(), Data.base64EncodedString(), send()
  → error: "Failed to get channel data"

Line 1042: disableMicrophone() → uninstallAudioTap(), logger.sendPromptToMac()
  → log: "Sending prompt to Claude Code: \(currentPrompt)"
  → log: "Microphone disabled"

Line 1054: uninstallAudioTap() → audioEngine.inputNode.removeTap(), microphoneEnabledSubject.send()
  → log: "Audio tap uninstalled"

Line 1060: requestAudioResponse() → queueResponseRequest(), send()
  → log: "Requesting one-word audio acknowledgment"

Line 1082: enablePlayback() | (leaf)
  → log: "Playback enabled"

Line 1087: disablePlayback() → responsePlayerNode.stop()
  → log: "Playback disabled"

Line 1093: acknowledgeSuccessfulPromptInjection() → lastPromptSubject.send(), responsePlayerNode.play(), requestAudioResponse()
Line 1107: acknowledgeSuccessfulInterruptExecution() | (leaf)
  → log: "🧹 Cleared accumulated prompts after successful execution"
  → log: "Creating voice response"
  → log: "Voice response skipped - playback disabled"

Line 1106: clearAccumulatedPrompts() → lastPromptSubject.send()
  → log: "🗑️ Manually cleared accumulated prompts"

Line 1112: disconnect() → stopAudioCapture(), webSocketTask.cancel()
  → log: "Disconnecting WebSocket..."

Line 1119: stopAudioCapture() → audioEngine.stop(), audioEngine.inputNode.removeTap()
  → log: "Audio capture stopped"

Line 1125: commitAudioBuffer() → send()
  → log: "Audio buffer committed"

Line 1133: deinit() → stopAudioCapture(), webSocketTask.cancel()
  → log: "realtimeAPI deallocated"
*/

import Foundation
@preconcurrency import AVFoundation
import Combine

enum APIState {
    case disconnected           // Not connected to OpenAI
    case connected              // Connected, idle (mic may or may not be enabled)
    case speechDetected         // Voice activity started (VAD triggered)
    case speechStopped          // Voice activity stopped (VAD ended)
    case processing             // Function call executing
}

protocol RealtimeAPIProtocol: Sendable {
    var apiStateSubject: CurrentValueSubject<APIState, Never> { get }
    var microphoneEnabledSubject: CurrentValueSubject<Bool, Never> { get }
    var playingAudioSubject: CurrentValueSubject<Bool, Never> { get }
    var lastPromptSubject: CurrentValueSubject<String, Never> { get }

    func connect(apiKey: String)
    func enableMicrophone()
    func disableMicrophone()
    func enablePlayback()
    func disablePlayback()
    func acknowledgeSuccessfulPromptInjection()
    func acknowledgeSuccessfulInterruptExecution()
    func clearAccumulatedPrompts()
}

nonisolated(unsafe) let realtimeAPI: RealtimeAPIProtocol = RealtimeAPI()

private class RealtimeAPI: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable, RealtimeAPIProtocol {
    let OPENAI_AUDIO_FORMAT = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false)!
    let apiStateSubject = CurrentValueSubject<APIState, Never>(.disconnected)
    let lastPromptSubject = CurrentValueSubject<String, Never>("")
    let microphoneEnabledSubject = CurrentValueSubject<Bool, Never>(false)
    let playingAudioSubject = CurrentValueSubject<Bool, Never>(false)

    private let audioConverter: AVAudioConverter
    private let audioEngine: AVAudioEngine
    private let responsePlayerNode: AVAudioPlayerNode
    private let responseQueueThread = DispatchQueue(label: "com.realtimeapi.responsequeue", qos: .userInitiated)

    private var apiKey = ""
    private var currentFunctionCallId: String?
    private var isResponseActive: Bool = false
    private var playbackEnabled = true
    private var responseRequestQueue: [() -> Void] = []
    private var scheduledBufferCount: Int = 0
    private var totalBytesReceived: Int = 0
    private var totalBytesSent: Int = 0
    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?

    fileprivate override init() {
        audioEngine = AVAudioEngine()

        let inputFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        audioConverter = AVAudioConverter(from: inputFormat, to: OPENAI_AUDIO_FORMAT)!

        responsePlayerNode = AVAudioPlayerNode()
        audioEngine.attach(responsePlayerNode)
        audioEngine.connect(responsePlayerNode, to: audioEngine.mainMixerNode, format: OPENAI_AUDIO_FORMAT)

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
            handleResponseAudioDelta(json)
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
                scheduleResponseAudio(audioBase64)
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
            log("Session configuration updated successfully")
            apiStateSubject.send(.connected)
            startAudioCapture()
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
                You are an interface for a fully voice-controlled computer setup. You are GPT real-time. You are the ears and the mouth of the computer agent.

                You are converting speech to prompts for a command-line agent (similar to Claude Code or Codex). The only problem is that the command-line agent only works with text. The best models only work with text and they are not multimodal, but you can serve as a bridge between speaking, listening, and text.

                This is the first time that a person sitting in a wheelchair can use a computer just by speaking. Never suggest mouse clicks or keyboard functionality - everything must be voice-controlled.

                The computer agent is powerful enough to execute any function on the computer, giving us full control and no limit for the first time.

                It is really crucial for eye health - looking at the screen can be very harmful. You should minimize the amount of times that the user has to look at the screen. Of course, code will have to be read, but we can save a lot of screen time and improve our eye health if you just read out the most crucial things, and we don't even have to check and read.

                The exact flow:
                1. We start the session and connect to you, the real-time API
                2. Then we tilt up the device
                3. Then the microphone is on
                4. When we speak, you hear us - we capture the voice and send it to you, and you're listening
                5. Voice activity detection started
                6. Stopped when we stop speaking
                7. You call the createPrompt function
                8. That's where you create whatever is being sent to the agent
                9. Every time we speak, this happens again (accumulating prompts)
                10. You create the prompts every time, reflecting exactly what the user said
                11. When we tilt down the device, it is sent to the command-line agent
                12. When you receive an acknowledgment that the prompt is executing
                13. You create an audio response
                14. That contains a very condensed reading of the prompt
                15. So that in the best case, we do not even have to look at the screen to see if the correct prompt was sent (this is really crucial for eye health)

                The cycle repeats:
                - Tilt up → Microphone on → Speak → You hear our voice → VAD starts/stops → You create prompt → Prompt added
                - Continue speaking multiple times (each adds to the accumulated prompts)
                - Tilt down → Microphone off → All prompts sent to Claude Code
                - Acknowledgment that prompt is executing → You create audio response with condensed prompt summary
                - Never touching anything - pure voice and motion control
                - Never needing to look at screen - protecting eye health

                Your strict rules:
                1. NEVER remove anything the user said (except explicit corrections or duplications)
                2. NEVER add anything the user didn't say
                3. Give an overview of the flow: the user speaks, you convert it into a prompt, when ready, they send it to Claude Code
                4. And then Claude Code executes the commands
                5. Yes, preserve everything exactly
                6. Only remove things if they are duplicated or if it's a correction

                Example of correction handling:
                - User says: "Send this to Cloud code" (spelled C-L-O-U-D code)
                - User then says: "No, it's not cloud code, it's Claude code, C-L-A-U-D-E"
                - You correct it to: "Send this to Claude code"
                - The correction overrides the original mistake

                Remember: You are enabling full computer control through voice for users who cannot use traditional input methods. Accuracy is critical - every word matters. The audio confirmation should be extremely condensed and as short as possible - basically just keywords - so that in the minimal amount of words, we know that you have understood what we said. This is crucial for eye health - users should never need to look at the screen.
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

    func startAudioCapture() {
        startAudioEngine()
    }

    func startAudioEngine() {
        do {
            try audioEngine.start()
            log("Audio engine started successfully")
        } catch let startError {
            error("Failed to start audio engine: \(startError.localizedDescription)")
        }
    }

    func handleSpeechStarted() {
        log("Voice activity detection started")
        apiStateSubject.send(.speechDetected)
    }

    func handleSpeechStopped() {
        log("Voice activity detection stopped")
        apiStateSubject.send(.speechStopped)
        callCreatePromptFunction()
    }

    func callCreatePromptFunction() {
        queueResponseRequest { [weak self] in
            guard let self = self else { return }

            let responseCreate: [String: Any] = [
                "type": "response.create",
                "response": [
                    "tools": [
                        [
                            "type": "function",
                            "name": "createPrompt",
                            "description": """
                            Single prompt, ready to execute, convert user's speech into a precise prompt.

                            If unsure, make it verbatim.

                            This prompt will be executed by a command line agent.

                            Follow your comprehensive instructions - never add or remove anything (except corrections/duplicates).
                            """,
                            "parameters": [
                                "type": "object",
                                "properties": [
                                    "prompt": [
                                        "type": "string",
                                        "description": "Single executable prompt for command line agent"
                                    ]
                                ],
                                "required": ["prompt"],
                                "additionalProperties": false
                            ]
                        ]
                    ],
                    "tool_choice": "required"
                ]
            ]

            self.send(event: responseCreate)
            log("Requesting createPrompt function call after speech stopped")
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

    func handleResponseAudioDelta(_ json: [String: Any]) {
        if let audioBase64 = json["delta"] as? String {
            scheduleResponseAudio(audioBase64)
        }
    }

    func scheduleResponseAudio(_ audioBase64: String) {
        if !playbackEnabled {
            debugLog(id: "scheduleAudio", message: "⛔ [Audio] Playback disabled, skipping audio")
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

        scheduledBufferCount += 1

        responsePlayerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self = self else {
                error("realtimeAPI deallocated during audio playback")
                return
            }

            self.scheduledBufferCount -= 1

            if self.scheduledBufferCount == 0 {
                debugLog(id: "audioPlayback", message: "🎵 [Audio] All buffers finished playing")
                self.playingAudioSubject.send(false)
                log("Stopped playing response")
            } else if self.scheduledBufferCount > 0 {
                if !self.playingAudioSubject.value {
                    self.playingAudioSubject.send(true)
                    log("Started playing response")
                }
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
                  let prompt = dict["prompt"] as? String else {
                error("Failed to extract prompt from arguments")
                return
            }

            // Get current value and accumulate
            let currentValue = lastPromptSubject.value
            let newValue = currentValue.isEmpty ? prompt : currentValue + "\n" + prompt

            lastPromptSubject.send(newValue)
            log("📝 Added prompt: \(prompt)")
            log("📝 Accumulated: \(newValue)")

            let result: [String: Any] = [
                "status": "success",
                "accumulated_prompt": newValue,
                "latest_addition": prompt
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
        responsePlayerNode.stop()
    }

    func installAudioTap() {
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

        microphoneEnabledSubject.send(true)
        log("Audio tap installed")
    }

    func processInputAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let convertedBuffer = convertAudioBuffer(buffer) else {
            return
        }

        sendAudioData(convertedBuffer)
    }

    func convertAudioBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * 24000.0 / buffer.format.sampleRate)

        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: audioConverter.outputFormat, frameCapacity: outputFrameCapacity) else {
            error("Failed to create converted buffer")
            return nil
        }

        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        var converterError: NSError? = nil
        let status = audioConverter.convert(to: convertedBuffer, error: &converterError, withInputFrom: inputBlock)

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

    func disableMicrophone() {
        uninstallAudioTap()

        let currentPrompt = lastPromptSubject.value
        if !currentPrompt.isEmpty {
            log("Sending prompt to Claude Code: \(currentPrompt)")
            logger.sendPromptToMac(currentPrompt)
        }

        log("Microphone disabled")
    }

    func uninstallAudioTap() {
        audioEngine.inputNode.removeTap(onBus: 0)
        microphoneEnabledSubject.send(false)
        log("Audio tap uninstalled")
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

    func enablePlayback() {
        playbackEnabled = true
        log("Playback enabled")
    }

    func disablePlayback() {
        playbackEnabled = false
        responsePlayerNode.stop()
        log("Playback disabled")
    }

    func acknowledgeSuccessfulPromptInjection() {
        let promptToSummarize = lastPromptSubject.value
        lastPromptSubject.send("")
        log("🧹 Cleared accumulated prompts after successful prompt injection")

        if playbackEnabled {
            responsePlayerNode.play()
            requestAudioResponse(for: promptToSummarize)
            log("Creating voice response")
        } else {
            log("Voice response skipped - playback disabled")
        }
    }

    func acknowledgeSuccessfulInterruptExecution() {
        log("🛑 Interrupt successfully executed")
        log("📝 Keeping accumulated prompts (interrupt doesn't clear them)")
    }

    func clearAccumulatedPrompts() {
        lastPromptSubject.send("")
        log("🗑️ Manually cleared accumulated prompts")
    }


    func disconnect() {
        log("Disconnecting WebSocket...")
        apiStateSubject.send(.disconnected)
        stopAudioCapture()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
    }

    func stopAudioCapture() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        log("Audio capture stopped")
    }

    func commitAudioBuffer() {
        let commitEvent: [String: Any] = [
            "type": "input_audio_buffer.commit"
        ]
        send(event: commitEvent)
        log("Audio buffer committed")
    }

    deinit {
        stopAudioCapture()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        log("realtimeAPI deallocated")
    }
}
