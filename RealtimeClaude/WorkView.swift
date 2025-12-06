import SwiftUI
import Combine
import Observation
import CoreMotion
import UIKit

let INTERRUPT_MESSAGE = "[Request interrupted by user]"

struct TiltProgressBar: View {
    let progress: Double
    let normalColor: Color
    let currentStatus: RecordingStatus

    init(progress: Double, normalColor: Color, currentStatus: RecordingStatus) {
        self.progress = progress
        self.normalColor = normalColor
        self.currentStatus = currentStatus
    }

    var fillColor: Color {
        if currentStatus == .disconnected {
            return .red
        } else if currentStatus == .restarting {
            return .gray
        }
        return normalColor
    }

    var body: some View {
        VStack {
            Spacer()
        }
        .frame(width: ACTUAL_SCREEN_WIDTH * (progress / 100) - 1, height: 10)
        .glassEffect(.clear.tint(fillColor.opacity(0.5)), in: .capsule)
    }
}

enum RecordingStatus {
    case disconnected
    case connected
    case isRecording
    case speechDetected
    case speechStopped
    case restarting

    var color: Color {
        switch self {
        case .disconnected: return .red
        case .connected: return .blue
        case .isRecording: return .green
        case .speechDetected: return .yellow
        case .speechStopped: return .orange
        case .restarting: return .gray
        }
    }

    var statusText: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connected: return "Connected"
        case .isRecording: return "Recording"
        case .speechDetected: return "Voice Activity Detected"
        case .speechStopped: return "Voice Activity Stopped"
        case .restarting: return "Restarting..."
        }
    }
}

extension MessageStatus {
    var color: Color {
        switch self {
        case .recording: return .white
        case .notSent: return .white
        case .sent: return .orange
        case .injected: return .green
        case .failed: return .red
        }
    }

    var statusText: String {
        switch self {
        case .recording: return "Recording..."
        case .notSent: return ""
        case .sent: return "Sending..."
        case .injected: return ""
        case .failed: return "Failed"
        }
    }
}

enum MessageAudioState: Sendable {
    case queued
    case processing
    case doneProcessing

    var color: Color {
        switch self {
        case .queued: return .gray
        case .processing: return .purple
        case .doneProcessing: return .green
        }
    }

    var statusText: String {
        switch self {
        case .queued: return "Queued"
        case .processing: return "Processing"
        case .doneProcessing: return "Done Processing"
        }
    }
}


struct ToggleBar: View {
    struct ToggleItem {
        let color: Color
        var isOn: Binding<Bool>?
        let icon: String?
        let text: String?
        let action: () -> Void

        init(color: Color, isOn: Binding<Bool>? = nil, icon: String? = nil, text: String? = nil, action: @escaping () -> Void) {
            self.color = color
            self.isOn = isOn
            self.icon = icon
            self.text = text
            self.action = action
        }
    }

    let items: [ToggleItem]
    let height: CGFloat

    init(items: [ToggleItem], height: CGFloat = CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_TOP")) * 2) {
        self.items = items
        self.height = height
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                Button {
                    item.action()
                } label: {
                    VStack(spacing: 5) {
                        if let icon = item.icon {
                            Image(systemName: icon)
                                .font(.system(size: 30, weight: .semibold))
                                .foregroundColor(item.color)
                        }

                        if let text = item.text {
                            Text(text)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(item.color)
                        }

                        Spacer()
                    }
                    .padding(10)
                    .glassEffect(.regular.tint(item.color.opacity(item.isOn?.wrappedValue == true ? 0.5 : 0.1)).interactive(), in: .capsule)
                    .padding(10)
                }
            }
        }
        .frame(height: height)
    }
}

struct WorkView: View {
    @Bindable var viewModel: WorkViewModel
    @Binding var showLogs: Bool

    var body: some View {
        ZStack {
            if viewModel.allMessages.isEmpty {
                VStack {
                    Spacer()
                    Text("Hold up to record")
                        .font(.headline)
                        .foregroundColor(.gray)
                    Spacer()
                }
                .frame(height: ACTUAL_SCREEN_HEIGHT)
            } else {
                ScrollViewReader { proxy in
                        List {
                            Color.clear
                                .frame(height: CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_BOTTOM")) * 2)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets())
                                .id("topSpacer")

                            ForEach(viewModel.allMessages) { message in
                                VStack(spacing: 0) {
                                    ZStack(alignment: .bottomTrailing) {
                                        if message.text == INTERRUPT_MESSAGE {
                                            HStack {
                                                HStack(spacing: 6) {
                                                    if message.status == .sent {
                                                        ProgressView()
                                                            .scaleEffect(0.5)
                                                            .frame(width: 10, height: 10)
                                                    } else {
                                                        Image(systemName: message.status == .injected ? "stop.circle.fill" : "hand.raised.circle.fill")
                                                            .font(.system(size: 10))
                                                            .foregroundColor(message.status == .injected ? .red : message.status.color)
                                                    }
                                                    Text(message.status == .sent ? "Request interrupt sent" : "Request interrupted")
                                                        .font(.system(size: 10))
                                                        .foregroundColor(message.status == .injected ? .red : message.status.color)
                                                }

                                                Spacer()
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 2)
                                        } else {
                                            VStack(alignment: .leading, spacing: 4) {
                                                if message.role == "user" {
                                                    if let transcription = message.transcription {
                                                        Text("Transcription: \(transcription)")
                                                            .font(.caption)
                                                            .foregroundColor(.gray)
                                                            .frame(maxWidth: .infinity, alignment: .leading)
                                                    }

                                                    Text(message.text.isEmpty ? "" : "Prompt: \(message.text)")
                                                        .font(.body)
                                                        .foregroundColor(message.status.color)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                } else {
                                                    Text("Assistant: \(message.text)")
                                                        .font(.body)
                                                        .foregroundColor(message.status.color)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                }

                                                if let summary = message.summary {
                                                    Text("Summary: \(summary)")
                                                        .font(.caption)
                                                        .foregroundColor(.purple)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                }
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                        }
                                    }
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(message.text == INTERRUPT_MESSAGE && message.status == .injected ? Color.red.opacity(0.1) : message.status.color.opacity(0.1))
                                    )

                                    if message.text != INTERRUPT_MESSAGE {
                                        VStack {
                                            Spacer()
                                        }
                                        .frame(height: 10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .glassEffect(.clear.tint(message.audioState?.color ?? message.status.color), in: .capsule)
                                    }
                                }
                                .onTapGesture {
                                    viewModel.copyMessageToClipboard(message)
                                }
                                .onTapGesture(count: 2) {
                                    viewModel.replayAudioForMessage(message)
                                }
                                .id(message.id)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        viewModel.sendMessage(message.text)
                                    } label: {
                                        Label("Send", systemImage: "paperplane.fill")
                                    }
                                    .tint(.blue)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        viewModel.deleteMessage(message.id)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .tint(.red)
                                }
                            }

                            Color.clear
                                .frame(height: CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_TOP")) * 2)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets())
                                .id("bottomSpacer")
                        }
                        .listStyle(PlainListStyle())
                        .scrollContentBackground(.hidden)
                        .environment(\.defaultMinListRowHeight, 0)
                        .frame(height: ACTUAL_SCREEN_HEIGHT)
                        .onChange(of: viewModel.allMessages.count) { _ in
                            withAnimation {
                                proxy.scrollTo("topSpacer", anchor: .top)
                            }
                        }
                    }
                }

            VStack {
                Spacer()

                ToggleBar(items: [
                    ToggleBar.ToggleItem(
                        color: .blue,
                        isOn: $viewModel.isPlaybackEnabled,
                        icon: viewModel.isPlayingAudio ? "speaker.wave.3.fill" : "speaker.slash.fill",
                        action: {
                            viewModel.togglePlayback()
                        }
                    ),
                    ToggleBar.ToggleItem(
                        color: .green,
                        isOn: $viewModel.isMicrophoneEnabled,
                        icon: viewModel.isRecordingAudio ? "mic.fill" : "mic.slash.fill",
                        action: {
                            viewModel.isMicrophoneEnabled.toggle()
                        }
                    ),
                    ToggleBar.ToggleItem(
                        color: .red,
                        icon: "stop.circle.fill",
                        action: {
                            viewModel.stopClaudeCode()
                        }
                    ),
                    ToggleBar.ToggleItem(
                        color: .orange,
                        isOn: $showLogs,
                        icon: "doc.text.magnifyingglass",
                        action: {
                            showLogs.toggle()
                            if showLogs {
                                log("Log view shown")
                            } else {
                                log("Log view hidden")
                            }
                        }
                    )
                ])
            }

            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    Spacer()

                    VStack(spacing: 4) {
                        Text(viewModel.currentRecordingStatus == .isRecording ? "\(viewModel.currentRecordingStatus.statusText) (\(viewModel.audioInputSource))" : viewModel.currentRecordingStatus.statusText)
                            .font(.headline)
                            .foregroundColor(.white)

                        if let loadingStatus = viewModel.loadingStatus {
                            Text(loadingStatus)
                                .font(.caption)
                                .foregroundColor(.yellow)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_BOTTOM")))
                    .glassEffect(.regular.tint(viewModel.currentRecordingStatus.color.opacity(0.5)))
                    .padding(.horizontal, ACTUAL_SCREEN_WIDTH / 8)


                    Spacer()

                    ZStack(alignment: .center) {
                        TiltProgressBar(progress: viewModel.firstTiltProgress, normalColor: .blue, currentStatus: viewModel.currentRecordingStatus)
                        TiltProgressBar(progress: viewModel.secondTiltProgress, normalColor: .green, currentStatus: viewModel.currentRecordingStatus)
                        TiltProgressBar(progress: viewModel.thirdTiltProgress, normalColor: viewModel.currentRecordingStatus.color, currentStatus: viewModel.currentRecordingStatus)
                    }
                }
                .frame(height: CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_BOTTOM")) * 2)

                Spacer()
            }
        }
        .onAppear {
            viewModel.startMotionDetection()
        }
        .onDisappear {
            viewModel.stopMotionDetection()
        }
    }
}

@Observable
class WorkViewModel {
    var currentRecordingStatus: RecordingStatus = .disconnected
    var isRecordingAudio = false
    var isPlayingAudio = false
    var isMicrophoneEnabled = false {
        didSet {
            handleMicrophoneToggle()
        }
    }
    var isPlaybackEnabled = audioManager.getIsPlaybackEnabled()
    var audioInputSource = "Unknown"
    var loadingStatus: String? = nil

    var allMessages: [ConversationMessage] = []

    private let motionManager = CMMotionManager()
    var pitch: Double = 0
    var roll: Double = 0
    private var turningOnRecording = false

    var firstTiltProgress: Double {
        let pitchDegrees = pitch * (180 / .pi)
        let percentage = (90 - pitchDegrees) / 90 * 100
        return max(0, min(100, percentage))
    }

    var secondTiltProgress: Double {
        let pitchDegrees = pitch * (180 / .pi)
        let percentage = (-pitchDegrees) / 45 * 100
        return max(0, min(100, percentage))
    }

    var thirdTiltProgress: Double {
        let pitchDegrees = pitch * (180 / .pi)
        let percentage = ((-pitchDegrees) - 45) / 45 * 100
        return max(0, min(100, percentage))
    }

    private var cancellables = Set<AnyCancellable>()

    init() {
        realtimeAPI.apiStateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] apiState in
                guard let self = self else { return }
                log("API State changed: \(apiState)")

                switch apiState {
                case .disconnected:
                    self.currentRecordingStatus = .disconnected
                case .connected:
                    self.currentRecordingStatus = self.isRecordingAudio ? .isRecording : .connected
                case .speechDetected:
                    self.currentRecordingStatus = .speechDetected
                case .speechStopped:
                    self.currentRecordingStatus = .speechStopped
                case .restarting:
                    self.currentRecordingStatus = .restarting
                }
            }
            .store(in: &cancellables)

        audioManager.isRecordingAudioSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording in
                guard let self = self else { return }
                self.isRecordingAudio = isRecording
                if isRecording && self.currentRecordingStatus == .connected {
                    self.currentRecordingStatus = .isRecording
                } else if !isRecording && self.currentRecordingStatus == .isRecording { self.currentRecordingStatus = .connected }
            }
            .store(in: &cancellables)

        audioManager.isPlayingAudioSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPlaying in
                guard let self = self else { return }
                self.isPlayingAudio = isPlaying
            }
            .store(in: &cancellables)



        audioManager.audioInputSourceSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] inputSource in
                self?.audioInputSource = inputSource
            }
            .store(in: &cancellables)

        audioManager.isPlaybackEnabledSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEnabled in
                self?.isPlaybackEnabled = isEnabled
            }
            .store(in: &cancellables)

        realtimeAPI.conversationContextSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] conversationContext in
                self?.allMessages = conversationContext.sorted { $0.timestamp > $1.timestamp }
            }
            .store(in: &cancellables)

        realtimeAPI.loadingStatusSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.loadingStatus = status
            }
            .store(in: &cancellables)
    }

    func startMotionDetection() {
        guard motionManager.isDeviceMotionAvailable else {
            log("Device motion not available")
            return
        }

        motionManager.deviceMotionUpdateInterval = 0.1
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] data, error in
            guard let self = self,
                  let attitude = data?.attitude else { return }

            self.pitch = attitude.pitch
            self.roll = attitude.roll

            let pitchDegrees = attitude.pitch * (180 / .pi)

            if !self.isMicrophoneEnabled {
                if pitchDegrees < -45 && !self.turningOnRecording {
                    debugLog(id: "deviceTilt", message: "📱 [Motion] Tilted down: \(Int(pitchDegrees))° (enabling mic)")
                    log("Device tilted down > 45 degrees - enabling microphone")
                    self.turningOnRecording = true
                    audioManager.startRecording()
                } else if pitchDegrees > -45 && self.turningOnRecording {
                    debugLog(id: "deviceTilt", message: "📱 [Motion] Tilted back: \(Int(pitchDegrees))° (disabling mic)")
                    log("Device tilted back - disabling microphone")
                    self.turningOnRecording = false
                    audioManager.stopRecording()
                } else if pitchDegrees < -45 && self.turningOnRecording {
                    debugLog(id: "deviceTilt", message: "📱 [Motion] Still tilted: \(Int(pitchDegrees))° (mic enabled)")
                } else {
                    debugLog(id: "deviceTilt", message: "📱 [Motion] Still upright: \(Int(pitchDegrees))° (mic disabled)")
                }
            } else {
                debugLog(id: "deviceTilt", message: "⛔ [Motion] Tilt detection disabled (override ON)")
            }
        }
    }

    func handleMicrophoneToggle() {
        if isMicrophoneEnabled {
            log("Microphone override ON - enabling microphone manually")
            audioManager.startRecording()
        } else {
            log("Microphone override OFF - disabling microphone, tilt detection active")
            audioManager.stopRecording()
        }
    }

    func handlePlaybackToggle() {
        if isPlaybackEnabled {
            log("Playback enabled")
            audioManager.enablePlayback()
        } else {
            log("Playback disabled")
            audioManager.disablePlayback()
        }
    }

    func togglePlayback() {
        if isPlaybackEnabled {
            audioManager.disablePlayback()
        } else {
            audioManager.enablePlayback()
        }
    }


    func copyMessageToClipboard(_ message: ConversationMessage) {
        guard message.text != INTERRUPT_MESSAGE else { return }

        UIPasteboard.general.string = message.text
        log("Copied message to clipboard: \(message.text.prefix(50))...")
    }

    func replayAudioForMessage(_ message: ConversationMessage) {
        guard let audioData = message.audioData else {
            log("No audio data to replay")
            return
        }

        log("Replaying audio (\(audioData.count) bytes)")
        let audioBase64 = audioData.base64EncodedString()
        audioManager.scheduleOutputAudioBuffer(audioBase64, resetCount: true, onBufferPlayed: nil)
    }


    func sendMessage(_ content: String) {
        log("📤 Manually sending message: \(content)")
        logger.sendPromptToMac(content)
    }

    func deleteMessage(_ id: UUID) {
        guard let message = allMessages.first(where: { $0.id == id }) else { return }

        if message.status != .injected {
            realtimeAPI.clearAccumulatedPrompts()
            log("🗑️ Deleted current message and cleared accumulated prompts")
        } else {
            log("🗑️ Deleted message (view only)")
        }
    }

    func stopClaudeCode() {
        log("🛑 Adding stop signal to conversation")
        _ = realtimeAPI.addInterruptMessage(INTERRUPT_MESSAGE)
        logger.sendPromptToMac(INTERRUPT_MESSAGE)
    }

    deinit {
        stopMotionDetection()
    }

    func stopMotionDetection() {
        motionManager.stopDeviceMotionUpdates()
    }
}
