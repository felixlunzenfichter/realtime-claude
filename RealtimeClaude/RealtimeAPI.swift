import Foundation
@preconcurrency import AVFoundation
import Combine

enum APIState {
    case disconnected
    case connected
    case restarting
}

enum MessageStatus: Sendable {
    case recording
    case notSent
    case sent
    case injected
    case failed
}

struct ConversationMessage: Identifiable, Sendable {
    let id = UUID()
    var timestamp: Date
    var transcription: String?
    var text: String
    let role: String
    var summary: String?
    var audioState: MessageAudioState?
    var audioData: Data?
    var status: MessageStatus = .notSent
    var segments: [TranscriptionSegment] = []

    init(transcription: String? = nil, text: String, role: String, summary: String? = nil, audioState: MessageAudioState? = nil, audioData: Data? = nil, status: MessageStatus = .notSent, segments: [TranscriptionSegment] = []) {
        self.timestamp = Date()
        self.transcription = transcription
        self.text = text
        self.role = role
        self.summary = summary
        self.audioState = audioState
        self.audioData = audioData
        self.status = status
        self.segments = segments
    }
}

protocol RealtimeAPIProtocol: Sendable {
    var apiStateSubject: CurrentValueSubject<APIState, Never> { get }
    var conversationContextSubject: CurrentValueSubject<[ConversationMessage], Never> { get }
    var loadingStatusSubject: CurrentValueSubject<String?, Never> { get }

    func saveAPIKey(_ apiKey: String?)
    func acknowledgeSuccessfulPromptInjection(summary: String)
    func acknowledgeSuccessfulInterruptExecution()
    func clearAccumulatedPrompts()
    func processInputAudioBuffer(_ data: Data)
    func finalizeMessage()
    func restart()
    func addAssistantMessage(_ text: String, summary: String)
    func addInterruptMessage(_ text: String) -> UUID
    func updateAPIState(_ newState: APIState)
}

nonisolated(unsafe) let realtimeAPI: RealtimeAPIProtocol = RealtimeAPI()

private class RealtimeAPI: @unchecked Sendable, RealtimeAPIProtocol {
    let apiStateSubject = CurrentValueSubject<APIState, Never>(.disconnected)
    let conversationContextSubject = CurrentValueSubject<[ConversationMessage], Never>([])
    let loadingStatusSubject = CurrentValueSubject<String?, Never>(nil)

    private var currentUserMessageId: UUID?
    private var transcriptionCancellable: AnyCancellable?
    private var connectionStatusCancellable: AnyCancellable?
    private var accumulatedText: String = ""

    private let sampleRate: Double = 16000

    init() {
        log("RealtimeAPI initialized with Mac-based transcription")
        setupTranscriptionSubscription()
        setupConnectionStatusMonitoring()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            audioManager.startAudioEngine()
            log("Audio engine started")
        }
    }

    private func setupTranscriptionSubscription() {
        transcriptionCancellable = logger.transcriptionSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                guard let self = self else { return }

                if update.isRaw {
                    self.handleRawTranscription(update.transcription, segments: update.segments)
                } else if update.isFinal {
                    self.handleFinalTranscription(transcription: update.transcription, prompt: update.prompt ?? update.transcription, summary: update.summary, segments: update.segments)
                } else {
                    self.handleInterimTranscription(transcription: update.transcription, prompt: update.prompt ?? update.transcription, summary: update.summary, segments: update.segments)
                }
            }
        log("Subscribed to Mac transcription updates")
    }

    private func setupConnectionStatusMonitoring() {
        connectionStatusCancellable = logger.macConnectionReadySubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                guard let self = self else { return }

                if isConnected && self.apiStateSubject.value != .connected {
                    self.updateAPIState(.connected)
                } else if !isConnected && self.apiStateSubject.value == .connected {
                    self.updateAPIState(.disconnected)
                }
            }
        log("Monitoring Mac server connection status")
    }

    func saveAPIKey(_ apiKey: String?) {
        if let apiKey = apiKey {
            saveToKeychain(key: "OPENAI_API_KEY", value: apiKey)
            log("Saved API key to Keychain")
        }
    }

    func processInputAudioBuffer(_ data: Data) {
    }

    private func handleRawTranscription(_ text: String, segments: [TranscriptionSegment]) {
        if text.isEmpty { return }

        var currentContext = conversationContextSubject.value

        if let userId = currentUserMessageId,
           let index = currentContext.firstIndex(where: { $0.id == userId }) {
            currentContext[index].transcription = text
            currentContext[index].timestamp = Date()
            currentContext[index].status = .recording
            currentContext[index].segments = segments
            conversationContextSubject.send(currentContext)
        } else {
            var userMessage = ConversationMessage(
                transcription: text,
                text: "",
                role: "user",
                audioState: .processing,
                segments: segments
            )
            userMessage.status = .recording
            currentUserMessageId = userMessage.id
            currentContext.insert(userMessage, at: 0)
            conversationContextSubject.send(currentContext)
        }
    }

    private func handleInterimTranscription(transcription: String, prompt: String, summary: String?, segments: [TranscriptionSegment]) {
        if prompt.isEmpty { return }

        var currentContext = conversationContextSubject.value

        if let userId = currentUserMessageId,
           let index = currentContext.firstIndex(where: { $0.id == userId }) {
            currentContext[index].transcription = transcription
            currentContext[index].text = prompt
            currentContext[index].summary = summary
            currentContext[index].timestamp = Date()
            currentContext[index].status = .recording
            currentContext[index].segments = segments
            conversationContextSubject.send(currentContext)
        } else {
            var userMessage = ConversationMessage(
                transcription: transcription,
                text: prompt,
                role: "user",
                summary: summary,
                audioState: .processing,
                segments: segments
            )
            userMessage.status = .recording
            currentUserMessageId = userMessage.id
            currentContext.insert(userMessage, at: 0)
            conversationContextSubject.send(currentContext)
        }
    }

    private func handleFinalTranscription(transcription: String, prompt: String, summary: String?, segments: [TranscriptionSegment]) {
        if !prompt.isEmpty {
            accumulatedText = prompt
            log("Final transcription: \(accumulatedText)")
        }

        var currentContext = conversationContextSubject.value

        if let userId = currentUserMessageId,
           let index = currentContext.firstIndex(where: { $0.id == userId }) {
            currentContext[index].transcription = transcription
            currentContext[index].text = accumulatedText.isEmpty ? "..." : accumulatedText
            currentContext[index].timestamp = Date()
            currentContext[index].audioState = .processing
            currentContext[index].segments = segments
            conversationContextSubject.send(currentContext)
        }

        finalizeMessage()
    }

    func finalizeMessage() {
        guard !accumulatedText.isEmpty else {
            log("No text to finalize")
            return
        }

        var currentContext = conversationContextSubject.value

        if let userId = currentUserMessageId,
           let index = currentContext.firstIndex(where: { $0.id == userId }) {
            currentContext[index].text = accumulatedText
            currentContext[index].audioState = .queued
            currentContext[index].status = .sent
            conversationContextSubject.send(currentContext)

            log("Sending message to Mac: \(accumulatedText)")
            logger.sendPromptToMac(accumulatedText)
        }

        accumulatedText = ""

        updateAPIState(.connected)
    }

    func acknowledgeSuccessfulPromptInjection(summary: String) {
        var currentContext = conversationContextSubject.value

        guard let lastUserMessage = currentContext.first(where: { $0.role == "user" && $0.status == .sent }) else {
            log("No user message to acknowledge")
            return
        }

        guard let index = currentContext.firstIndex(where: { $0.id == lastUserMessage.id }) else {
            log("Could not find user message in context")
            return
        }

        currentContext[index].summary = summary
        currentContext[index].audioState = .doneProcessing
        currentContext[index].status = .injected
        conversationContextSubject.send(currentContext)

        currentUserMessageId = nil

        log("Acknowledged: \(lastUserMessage.text)")
        log("Summary: \(summary)")

        if audioManager.getIsPlaybackEnabled() {
            speakWithTTS(text: summary, messageId: lastUserMessage.id)
        }
    }

    func acknowledgeSuccessfulInterruptExecution() {
        log("Interrupt acknowledged")
    }

    func clearAccumulatedPrompts() {
        if let userId = currentUserMessageId {
            var currentContext = conversationContextSubject.value
            if let index = currentContext.firstIndex(where: { $0.id == userId }) {
                currentContext[index].text = "[cancelled]"
                currentContext[index].status = .failed
                conversationContextSubject.send(currentContext)
            }
            currentUserMessageId = nil
            log("Marked current user message as cancelled")
        }
        accumulatedText = ""
    }

    func restart() {
        log("Restarting...")

        accumulatedText = ""
        conversationContextSubject.send([])
        currentUserMessageId = nil

        updateAPIState(.connected)
        log("Restart complete")
    }

    func addAssistantMessage(_ text: String, summary: String) {
        let message = ConversationMessage(
            text: text,
            role: "assistant",
            summary: summary,
            audioState: .queued
        )

        var currentContext = conversationContextSubject.value
        currentContext.insert(message, at: 0)
        conversationContextSubject.send(currentContext)

        log("Added assistant message: \(text)")

        if audioManager.getIsPlaybackEnabled() {
            speakWithTTS(text: summary, messageId: message.id)
        }
    }

    func addInterruptMessage(_ text: String) -> UUID {
        var message = ConversationMessage(
            text: text,
            role: "user",
            audioState: nil
        )
        message.status = .sent

        var currentContext = conversationContextSubject.value
        currentContext.insert(message, at: 0)
        conversationContextSubject.send(currentContext)

        log("Added interrupt message: \(text)")
        return message.id
    }

    private func speakWithTTS(text: String, messageId: UUID) {
        guard let apiKey = loadFromKeychain(key: "OPENAI_API_KEY") else {
            error("No API key for TTS")
            return
        }

        updateMessageAudioState(messageId: messageId, newState: .processing)

        let url = URL(string: "https://api.openai.com/v1/audio/speech")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "tts-1",
            "input": text,
            "voice": "fable",
            "response_format": "pcm"
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            error("Failed to serialize TTS request")
            return
        }
        request.httpBody = jsonData

        log("TTS: \(text)")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, requestError in
            guard let self = self else { return }

            if let requestError = requestError {
                error("TTS failed: \(requestError.localizedDescription)")
                return
            }

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                error("TTS bad response")
                return
            }

            guard let audioData = data else {
                error("TTS no data")
                return
            }

            log("TTS received \(audioData.count) bytes")

            var currentContext = self.conversationContextSubject.value
            if let index = currentContext.firstIndex(where: { $0.id == messageId }) {
                currentContext[index].audioData = audioData
                self.conversationContextSubject.send(currentContext)
            }

            let audioBase64 = audioData.base64EncodedString()
            audioManager.scheduleOutputAudioBuffer(audioBase64, resetCount: true, onBufferPlayed: nil)

            DispatchQueue.main.async {
                self.updateMessageAudioState(messageId: messageId, newState: .doneProcessing)
            }
        }.resume()
    }

    private func updateMessageAudioState(messageId: UUID, newState: MessageAudioState) {
        var currentContext = conversationContextSubject.value
        guard let index = currentContext.firstIndex(where: { $0.id == messageId }) else { return }
        currentContext[index].audioState = newState
        conversationContextSubject.send(currentContext)
    }

    func updateAPIState(_ newState: APIState) {
        let emoji: String
        switch newState {
        case .disconnected: emoji = "🔴"
        case .connected: emoji = "🟢"
        case .restarting: emoji = "🔄"
        }
        log("\(emoji) State: \(newState)")
        apiStateSubject.send(newState)
    }

    private func updateLoadingStatus(_ status: String?) {
        if let status = status {
            log("📊 \(status)")
        }
        loadingStatusSubject.send(status)
    }

    private func saveToKeychain(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }
}
