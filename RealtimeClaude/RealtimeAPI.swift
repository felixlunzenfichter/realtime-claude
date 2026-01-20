import Foundation
@preconcurrency import AVFoundation
import Combine

enum APIState {
    case disconnected
    case connected
}

struct ConversationMessage: Identifiable, Sendable {
    let id: UUID
    var timestamp: Date
    var transcription: String?
    var prompt: String
    let role: String
    var summary: String?
    var audioData: Data?
    var isPlaying: Bool = false

    init(id: UUID = UUID(), transcription: String? = nil, prompt: String, role: String, summary: String? = nil, audioData: Data? = nil) {
        self.id = id
        self.timestamp = Date()
        self.transcription = transcription
        self.prompt = prompt
        self.role = role
        self.summary = summary
        self.audioData = audioData
    }
}

protocol RealtimeAPIProtocol: Sendable {
    var apiStateSubject: CurrentValueSubject<APIState, Never> { get }
    var conversationContextSubject: CurrentValueSubject<[ConversationMessage], Never> { get }
    var loadingStatusSubject: CurrentValueSubject<String?, Never> { get }
    var claudeIsActiveSubject: CurrentValueSubject<Bool, Never> { get }

    func saveAPIKey(_ apiKey: String?)
    func stopCurrentRecording()
    func addInterruptMessage(_ text: String) -> UUID
    func createRecordingMessage() -> UUID
    func connect()
    func disconnect()
    func deleteMessage(id: UUID)
    func updateClaudeActiveState(_ isActive: Bool)
    func updateTranscription(messageId: UUID, text: String)
    func updatePrompt(messageId: UUID, text: String)
    func updateSummary(messageId: UUID, text: String)
}

nonisolated(unsafe) let realtimeAPI: RealtimeAPIProtocol = RealtimeAPI()

private class RealtimeAPI: @unchecked Sendable, RealtimeAPIProtocol {
    let apiStateSubject = CurrentValueSubject<APIState, Never>(.disconnected)
    let conversationContextSubject = CurrentValueSubject<[ConversationMessage], Never>([])
    let loadingStatusSubject = CurrentValueSubject<String?, Never>(nil)
    let claudeIsActiveSubject = CurrentValueSubject<Bool, Never>(false)

    private var connectionStatusCancellable: AnyCancellable?
    private var audioPlaybackCancellable: AnyCancellable?

    private let sampleRate: Double = 16000

    init() {
        log("RealtimeAPI initialized with Mac-based transcription")
        setupAudioPlaybackTracking()
    }

    private func setupAudioPlaybackTracking() {
        audioPlaybackCancellable = audioManager.currentPlayingMessageIdSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playingMessageId in
                guard let self = self else { return }

                var currentContext = self.conversationContextSubject.value

                for index in currentContext.indices {
                    if let playingMessageId = playingMessageId, currentContext[index].id == playingMessageId {
                        currentContext[index].isPlaying = true
                        log("Message \(playingMessageId) is now playing")
                    } else {
                        currentContext[index].isPlaying = false
                    }
                }

                self.conversationContextSubject.send(currentContext)
            }
        log("Audio playback tracking initialized")
    }

    func saveAPIKey(_ apiKey: String?) {
        if let apiKey = apiKey {
            saveToKeychain(key: "OPENAI_API_KEY", value: apiKey)
            log("Saved API key to Keychain")
        }
    }

    func updateTranscription(messageId: UUID, text: String) {
        guard !text.isEmpty else { return }

        var currentContext = conversationContextSubject.value

        if let index = currentContext.firstIndex(where: { $0.id == messageId }) {
            currentContext[index].transcription = text
            currentContext[index].timestamp = Date()
            conversationContextSubject.send(currentContext)
            log("Successful transcription")
        } else {
            let newMessage = ConversationMessage(
                id: messageId,
                transcription: text,
                prompt: "",
                role: "user"
            )
            currentContext.insert(newMessage, at: 0)
            conversationContextSubject.send(currentContext)
            log("Created new user message with ID \(messageId.uuidString)")
        }
    }

    func updatePrompt(messageId: UUID, text: String) {
        guard !text.isEmpty else { return }

        var currentContext = conversationContextSubject.value

        if let index = currentContext.firstIndex(where: { $0.id == messageId }) {
            currentContext[index].prompt = text
            currentContext[index].timestamp = Date()
            conversationContextSubject.send(currentContext)
            log("Successful prompt creation")
        } else {
            let newMessage = ConversationMessage(
                id: messageId,
                prompt: text,
                role: "assistant"
            )
            currentContext.insert(newMessage, at: 0)
            conversationContextSubject.send(currentContext)
            log("Created new assistant message with ID \(messageId.uuidString)")
        }
    }

    func updateSummary(messageId: UUID, text: String) {
        guard !text.isEmpty else { return }

        var currentContext = conversationContextSubject.value

        guard let index = currentContext.firstIndex(where: { $0.id == messageId }) else {
            error("Message with ID \(messageId.uuidString) NOT FOUND in updateSummary")
            return
        }

        currentContext[index].summary = text
        currentContext[index].timestamp = Date()
        conversationContextSubject.send(currentContext)

        if currentContext[index].role == "user" {
            claudeIsActiveSubject.send(true)
        }

        log("Successful summary creation")

        #if !IS_TEST || MANUAL_TESTING
        if audioManager.isPlaybackEnabledSubject.value {
            speakWithTTS(text: text, messageId: messageId)
        }
        #endif
    }

    func stopCurrentRecording() {
        log("Stopped current recording session")
    }

    func createRecordingMessage() -> UUID {
        let userMessage = ConversationMessage(
            transcription: "",
            prompt: "",
            role: "user"
        )

        var currentContext = conversationContextSubject.value
        currentContext.insert(userMessage, at: 0)
        conversationContextSubject.send(currentContext)

        log("Created new recording message with ID: \(userMessage.id)")
        return userMessage.id
    }

    func addInterruptMessage(_ text: String) -> UUID {
        let message = ConversationMessage(
            prompt: text,
            role: "user"
        )

        var currentContext = conversationContextSubject.value
        currentContext.insert(message, at: 0)
        conversationContextSubject.send(currentContext)

        log("Added interrupt message: \(text)")
        return message.id
    }

    private func speakWithTTS(text: String, messageId: UUID) {
        guard !text.isEmpty else {
            error("Skipping TTS - empty text")
            return
        }

        guard let apiKey = loadFromKeychain(key: "OPENAI_API_KEY") else {
            error("No API key for TTS")
            return
        }

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
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                let responseBody = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no body"
                error("TTS bad response: status=\(statusCode), body=\(responseBody)")
                return
            }

            guard let audioData = data else {
                error("TTS no data")
                return
            }

            log("TTS received \(audioData.count) bytes")

            var currentContext = self.conversationContextSubject.value
            guard let index = currentContext.firstIndex(where: { $0.id == messageId }) else {
                error("Message with ID \(messageId.uuidString) NOT FOUND when storing audio")
                return
            }

            currentContext[index].audioData = audioData
            self.conversationContextSubject.send(currentContext)

            audioManager.play(audio: audioData, id: messageId)
        }.resume()
    }

    func connect() {
        guard apiStateSubject.value != .connected else { return }
        log("🟢 State: connected")
        apiStateSubject.send(.connected)
    }

    func disconnect() {
        guard apiStateSubject.value != .disconnected else { return }
        log("🔴 State: disconnected")
        apiStateSubject.send(.disconnected)
    }

    func deleteMessage(id: UUID) {
        var context = conversationContextSubject.value
        context.removeAll { $0.id == id }
        conversationContextSubject.send(context)
    }

    func updateClaudeActiveState(_ isActive: Bool) {
        guard claudeIsActiveSubject.value != isActive else { return }
        claudeIsActiveSubject.send(isActive)
        log("Claude active state updated: \(isActive)")
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
