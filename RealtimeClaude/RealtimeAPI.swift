import Foundation
@preconcurrency import AVFoundation
import Combine

enum APIState {
    case disconnected
    case connected
    case restarting
}

struct ConversationMessage: Identifiable, Sendable {
    let id = UUID()
    var timestamp: Date
    var transcription: String?
    var prompt: String
    let role: String
    var summary: String?
    var audioData: Data?
    var isPlaying: Bool = false

    init(transcription: String? = nil, prompt: String, role: String, summary: String? = nil, audioData: Data? = nil) {
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

    func saveAPIKey(_ apiKey: String?)
    func acknowledgeSuccessfulPromptInjection(summary: String, messageId: UUID)
    func acknowledgeSuccessfulInterruptExecution()
    func clearAccumulatedPrompts()
    func finalizeMessage(messageId: UUID)
    func stopCurrentRecording()
    func restart()
    func addAssistantMessage(_ text: String, summary: String)
    func addInterruptMessage(_ text: String) -> UUID
    func updateAPIState(_ newState: APIState)
    func createRecordingMessage() -> UUID
    func connect()
    func disconnect()
    func deleteMessage(id: UUID)
}

nonisolated(unsafe) let realtimeAPI: RealtimeAPIProtocol = RealtimeAPI()

private class RealtimeAPI: @unchecked Sendable, RealtimeAPIProtocol {
    let apiStateSubject = CurrentValueSubject<APIState, Never>(.disconnected)
    let conversationContextSubject = CurrentValueSubject<[ConversationMessage], Never>([])
    let loadingStatusSubject = CurrentValueSubject<String?, Never>(nil)

    private var transcriptionCancellable: AnyCancellable?
    private var connectionStatusCancellable: AnyCancellable?
    private var audioPlaybackCancellable: AnyCancellable?
    private var accumulatedText: String = ""

    private let sampleRate: Double = 16000

    init() {
        log("RealtimeAPI initialized with Mac-based transcription")
        setupTranscriptionSubscription()
        setupAudioPlaybackTracking()
    }

    private func setupTranscriptionSubscription() {
        transcriptionCancellable = logger.transcriptionSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] update in
                guard let self = self else { return }

                debugLog(id: "promptFlow", message: "Received TranscriptionUpdate: status='\(update.status)', transcription='\(update.transcription)', prompt='\(update.prompt ?? "nil")', summary='\(update.summary ?? "nil")', isFinal=\(update.isFinal), isRaw=\(update.isRaw), messageId=\(update.messageId?.uuidString ?? "nil")")

                if update.isRaw || update.status == "final_chunk" {
                    debugLog(id: "promptFlow", message: "Calling updateTranscription() for raw update (status: \(update.status))")
                    self.updateTranscription(update.transcription, messageId: update.messageId)
                } else if update.isFinal {
                    debugLog(id: "promptFlow", message: "Calling updatePrompt() for final update with status '\(update.status)'")
                    self.updatePrompt(transcription: update.transcription, prompt: update.prompt ?? update.transcription, summary: update.summary, status: update.status, messageId: update.messageId)
                } else {
                    log("Update is neither raw nor final - IGNORING")
                }
            }
        log("Subscribed to Mac transcription updates")
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

    private func updateTranscription(_ text: String, messageId: UUID?) {
        if text.isEmpty { return }

        guard let messageId = messageId else {
            error("updateTranscription called without messageId")
            return
        }

        var currentContext = conversationContextSubject.value

        if let index = currentContext.firstIndex(where: { $0.id == messageId }) {
            currentContext[index].transcription = text
            currentContext[index].timestamp = Date()
            conversationContextSubject.send(currentContext)
        } else {
            error("Message with ID \(messageId.uuidString) NOT FOUND in updateTranscription")
        }
    }

    private func updatePrompt(transcription: String, prompt: String, summary: String?, status: String, messageId: UUID?) {
        guard let messageId = messageId else {
            error("updatePrompt called without messageId")
            return
        }

        debugLog(id: "promptFlow", message: "updatePrompt() called: status='\(status)', transcription='\(transcription)', prompt='\(prompt)', summary='\(summary ?? "nil")', messageId=\(messageId.uuidString)")

        if !prompt.isEmpty {
            accumulatedText = prompt
            log("Final transcription: \(accumulatedText)")
        }

        var currentContext = conversationContextSubject.value
        debugLog(id: "promptFlow", message: "Current context has \(currentContext.count) messages")

        guard let index = currentContext.firstIndex(where: { $0.id == messageId }) else {
            error("MESSAGE NOT FOUND in context array (ID: \(messageId.uuidString))")
            debugLog(id: "promptFlow", message: "Messages in context: \(currentContext.enumerated().map { "[\($0)] ID: \($1.id.uuidString), prompt: '\(String($1.prompt.prefix(30)))'" }.joined(separator: ", "))")
            return
        }

        debugLog(id: "promptFlow", message: "FOUND message at index \(index), before: prompt='\(currentContext[index].prompt)', summary='\(currentContext[index].summary ?? "nil")'")

        currentContext[index].transcription = transcription
        currentContext[index].prompt = accumulatedText.isEmpty ? "..." : accumulatedText
        currentContext[index].timestamp = Date()

        if status == "prompt" {
            debugLog(id: "promptFlow", message: "Handling prompt: updating prompt only")
            conversationContextSubject.send(currentContext)
            return
        }

        if status == "summary" {
            debugLog(id: "promptFlow", message: "Handling summary: updating summary and marking as complete")
            currentContext[index].summary = summary
            conversationContextSubject.send(currentContext)

            if let summary = summary, !summary.isEmpty {
                log("Received final message with summary")

                if audioManager.getIsPlaybackEnabled() {
                    speakWithTTS(text: summary, messageId: messageId)
                }
            }

            accumulatedText = ""
            updateAPIState(.connected)
            debugLog(id: "promptFlow", message: "Message complete with summary")
            return
        }

        currentContext[index].summary = summary

        debugLog(id: "promptFlow", message: "After update: prompt='\(currentContext[index].prompt)', summary='\(currentContext[index].summary ?? "nil")', publishing to conversationContextSubject")

        conversationContextSubject.send(currentContext)

        if let summary = summary, !summary.isEmpty {
            log("Received final message with summary")
            conversationContextSubject.send(currentContext)

            if audioManager.getIsPlaybackEnabled() {
                speakWithTTS(text: summary, messageId: messageId)
            }

            accumulatedText = ""
            updateAPIState(.connected)
            debugLog(id: "promptFlow", message: "Early return - message complete with summary")
            return
        } else {
            debugLog(id: "promptFlow", message: "Summary is nil or empty - proceeding to finalizeMessage with messageId")
        }

        debugLog(id: "promptFlow", message: "Calling finalizeMessage()")
        finalizeMessage(messageId: messageId)
    }

    func finalizeMessage(messageId: UUID) {
        guard !accumulatedText.isEmpty else {
            log("No text to finalize")
            return
        }

        var currentContext = conversationContextSubject.value

        guard let index = currentContext.firstIndex(where: { $0.id == messageId }) else {
            error("Message with ID \(messageId.uuidString) NOT FOUND in finalizeMessage")
            return
        }

        currentContext[index].prompt = accumulatedText
        conversationContextSubject.send(currentContext)

        log("Sending message to Mac: \(accumulatedText)")
        logger.sendPromptToMac(accumulatedText, messageId: messageId)

        accumulatedText = ""
        updateAPIState(.connected)
    }

    func finalizeMessage() {
        error("finalizeMessage() called without messageId - this should not happen")
    }

    func stopCurrentRecording() {
        log("Stopped current recording session")
    }

    func acknowledgeSuccessfulPromptInjection(summary: String, messageId: UUID) {
        debugLog(id: "promptFlow", message: "acknowledgeSuccessfulPromptInjection() called: summary='\(summary)', messageId=\(messageId.uuidString)")

        var currentContext = conversationContextSubject.value

        guard let index = currentContext.firstIndex(where: { $0.id == messageId }) else {
            error("Message with ID \(messageId.uuidString) NOT FOUND in context")
            debugLog(id: "promptFlow", message: "Messages in context: \(currentContext.enumerated().map { "[\($0)] ID: \($1.id.uuidString), prompt: '\(String($1.prompt.prefix(30)))'" }.joined(separator: ", "))")
            return
        }

        debugLog(id: "promptFlow", message: "FOUND message at index \(index), before: prompt='\(currentContext[index].prompt)', summary='\(currentContext[index].summary ?? "nil")'")

        currentContext[index].summary = summary

        debugLog(id: "promptFlow", message: "After update: prompt='\(currentContext[index].prompt)', summary='\(currentContext[index].summary ?? "nil")', publishing to conversationContextSubject")

        conversationContextSubject.send(currentContext)

        log("Acknowledged: \(currentContext[index].prompt)")
        log("Summary: \(summary)")

        if audioManager.getIsPlaybackEnabled() {
            speakWithTTS(text: summary, messageId: messageId)
        }
    }

    func acknowledgeSuccessfulPromptInjection(summary: String) {
        error("acknowledgeSuccessfulPromptInjection() called without messageId - this should not happen")
    }

    func acknowledgeSuccessfulInterruptExecution() {
        log("Interrupt acknowledged")
    }

    func clearAccumulatedPrompts() {
        accumulatedText = ""
        log("Cleared accumulated prompts")
    }

    func restart() {
        log("Restarting...")

        accumulatedText = ""
        conversationContextSubject.send([])

        updateAPIState(.connected)
        log("Restart complete")
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

    func addAssistantMessage(_ text: String, summary: String) {
        let message = ConversationMessage(
            prompt: text,
            role: "assistant",
            summary: summary
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

            audioManager.play(audio: audioData, id: messageId)
        }.resume()
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

    func connect() {
        guard apiStateSubject.value != .connected else { return }
        debugLog(id: "connect", message: "🟢 State: connected")
        updateAPIState(.connected)
    }

    func disconnect() {
        guard apiStateSubject.value != .disconnected else { return }
        debugLog(id: "disconnect", message: "🔴 State: disconnected")
        updateAPIState(.disconnected)
    }

    func deleteMessage(id: UUID) {
        var context = conversationContextSubject.value
        context.removeAll { $0.id == id }
        conversationContextSubject.send(context)
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
