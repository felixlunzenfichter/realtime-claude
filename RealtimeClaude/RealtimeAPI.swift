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
    var summary: String?
    var audioState: MessageAudioState?
    var audioData: Data?
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
}

nonisolated(unsafe) let realtimeAPI: RealtimeAPIProtocol = RealtimeAPI()

private class RealtimeAPI: @unchecked Sendable, RealtimeAPIProtocol {
    let apiStateSubject = CurrentValueSubject<APIState, Never>(.disconnected)
    let conversationContextSubject = CurrentValueSubject<[ConversationMessage], Never>([])
    let loadingStatusSubject = CurrentValueSubject<String?, Never>(nil)

    private var currentUserMessageId: UUID?
    private var transcriptionCancellable: AnyCancellable?
    private var accumulatedText: String = ""

    private let sampleRate: Double = 16000

    init() {
        log("RealtimeAPI initialized with Mac-based transcription")
        setupTranscriptionSubscription()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.updateAPIState(.connected)
            audioManager.startAudioEngine()
            log("Audio engine started - ready for recording")
        }
    }

    private func setupTranscriptionSubscription() {
        transcriptionCancellable = logger.transcriptionSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                guard let self = self else { return }

                if update.isFinal {
                    self.handleFinalTranscription(update.text)
                } else {
                    self.handleInterimTranscription(update.text)
                }
            }
        log("Subscribed to Mac transcription updates")
    }

    func saveAPIKey(_ apiKey: String?) {
        if let apiKey = apiKey {
            saveToKeychain(key: "OPENAI_API_KEY", value: apiKey)
            log("Saved API key to Keychain")
        }
    }

    func processInputAudioBuffer(_ data: Data) {
    }

    private func handleInterimTranscription(_ text: String) {
        if text.isEmpty { return }

        var currentContext = conversationContextSubject.value
        let displayText = accumulatedText.isEmpty ? text : accumulatedText + " " + text

        if let userId = currentUserMessageId,
           let index = currentContext.firstIndex(where: { $0.id == userId }) {
            currentContext[index].text = displayText + "..."
            conversationContextSubject.send(currentContext)
        } else {
            let userMessage = ConversationMessage(
                text: displayText + "...",
                role: "user",
                audioState: .processing
            )
            currentUserMessageId = userMessage.id
            currentContext.insert(userMessage, at: 0)
            conversationContextSubject.send(currentContext)
        }
    }

    private func handleFinalTranscription(_ text: String) {
        if !text.isEmpty {
            accumulatedText = accumulatedText.isEmpty ? text : accumulatedText + " " + text
            log("Accumulated: \(accumulatedText)")
        }

        var currentContext = conversationContextSubject.value

        if let userId = currentUserMessageId,
           let index = currentContext.firstIndex(where: { $0.id == userId }) {
            if accumulatedText.isEmpty {
                currentContext.remove(at: index)
                currentUserMessageId = nil
            } else {
                currentContext[index].text = accumulatedText
                currentContext[index].audioState = .processing
            }
            conversationContextSubject.send(currentContext)
        }
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
            conversationContextSubject.send(currentContext)
            log("Message finalized: \(accumulatedText)")
        }

        updateAPIState(.connected)
    }

    func acknowledgeSuccessfulPromptInjection(summary: String) {
        var currentContext = conversationContextSubject.value

        guard let lastUserMessage = currentContext.first(where: { $0.role == "user" && $0.audioState == .queued }) else {
            log("No user message to acknowledge")
            return
        }

        guard let index = currentContext.firstIndex(where: { $0.id == lastUserMessage.id }) else {
            log("Could not find user message in context")
            return
        }

        currentContext[index].summary = summary
        currentContext[index].audioState = .doneProcessing
        conversationContextSubject.send(currentContext)

        if currentUserMessageId == lastUserMessage.id {
            currentUserMessageId = nil
            accumulatedText = ""
        }

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
            currentContext.removeAll(where: { $0.id == userId })
            conversationContextSubject.send(currentContext)
            currentUserMessageId = nil
            log("Cleared current user message")
        }
        accumulatedText = ""
        logger.sendAudioControlToMac("reset")
    }

    func restart() {
        log("Restarting...")

        accumulatedText = ""
        conversationContextSubject.send([])
        currentUserMessageId = nil
        logger.sendAudioControlToMac("reset")

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

    private func updateAPIState(_ newState: APIState) {
        let emoji: String
        switch newState {
        case .disconnected: emoji = "🔴"
        case .connected: emoji = "🟢"
        case .speechDetected: emoji = "🎤"
        case .speechStopped: emoji = "⏸️"
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
