import SwiftUI
import Combine
import Observation
import CoreMotion

let INTERRUPT_MESSAGE = "[Request interrupted by user]"

struct TiltProgressBar: View {
    let progress: Double
    let fillColor: Color

    init(progress: Double, fillColor: Color = .blue) {
        self.progress = progress
        self.fillColor = fillColor
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
    case processing

    var color: Color {
        switch self {
        case .disconnected: return .red
        case .connected: return .blue
        case .isRecording: return .green
        case .speechDetected: return .yellow
        case .speechStopped: return .orange
        case .processing: return .purple
        }
    }

    var statusText: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connected: return "Connected"
        case .isRecording: return "Recording"
        case .speechDetected: return "Voice Activity Detected"
        case .speechStopped: return "Voice Activity Stopped"
        case .processing: return "Processing..."
        }
    }
}

enum MessageStatus {
    case notSent
    case sent
    case injected
    case failed

    var color: Color {
        switch self {
        case .notSent: return .white
        case .sent: return .orange
        case .injected: return .green
        case .failed: return .red
        }
    }

    var statusText: String {
        switch self {
        case .notSent: return ""
        case .sent: return "Sending..."
        case .injected: return ""
        case .failed: return "Failed ✗"
        }
    }

    var sortPriority: Int {
        switch self {
        case .failed: return 0
        case .notSent: return 1
        case .sent: return 2
        case .injected: return 3
        }
    }
}

struct Message: Identifiable {
    let id = UUID()
    var content: String
    let timestamp: Date
    var status: MessageStatus
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
                                ZStack(alignment: .bottomTrailing) {
                                    if message.content == INTERRUPT_MESSAGE {
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

                                            Text(message.timestamp, style: .time)
                                                .font(.system(size: 10))
                                                .foregroundColor(message.status == .injected ? Color.red.opacity(0.7) : message.status.color.opacity(0.7))
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 2)
                                    } else {
                                        Text(message.content.isEmpty ? "Recording..." : message.content)
                                            .font(.body)
                                            .foregroundColor(message.status.color)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                    }

                                    if message.content != INTERRUPT_MESSAGE {
                                        Text(message.timestamp, style: .time)
                                            .font(.system(size: 10))
                                            .foregroundColor(message.status.color.opacity(0.7))
                                    }
                                }
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(message.content == INTERRUPT_MESSAGE && message.status == .injected ? Color.red.opacity(0.1) : message.status.color.opacity(0.1))
                                )
                                .id(message.id)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        viewModel.sendMessage(message.content)
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
                            viewModel.isPlaybackEnabled.toggle()
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

                    Text(viewModel.currentRecordingStatus.statusText)
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_BOTTOM")))
                        .glassEffect(.regular.tint(viewModel.currentRecordingStatus.color.opacity(0.5)))
                        .padding(.horizontal, ACTUAL_SCREEN_WIDTH / 8)


                    Spacer()

                    ZStack(alignment: .center) {
                        TiltProgressBar(progress: viewModel.firstTiltProgress, fillColor: viewModel.currentRecordingStatus == .disconnected ? .red : .blue)
                        TiltProgressBar(progress: viewModel.secondTiltProgress, fillColor: viewModel.currentRecordingStatus == .disconnected ? .red : .green)
                        TiltProgressBar(progress: viewModel.thirdTiltProgress, fillColor: viewModel.currentRecordingStatus == .disconnected ? .red : viewModel.currentRecordingStatus.color)
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
    var currentRecordingStatus: RecordingStatus = .disconnected {
        didSet {
            log("Recording status changed: \(oldValue) → \(currentRecordingStatus)")
            if currentRecordingStatus == .connected {
                let currentPrompt = realtimeAPI.lastPromptSubject.value
                if !currentPrompt.isEmpty {
                    log("Sending prompt to Claude Code: \(currentPrompt)")
                    logger.sendPromptToMac(currentPrompt)
                }
            }
        }
    }
    var isRecordingAudio = false
    var isPlayingAudio = false
    var isMicrophoneEnabled = false {
        didSet {
            handleMicrophoneToggle()
        }
    }
    var isPlaybackEnabled = true {
        didSet {
            handlePlaybackToggle()
        }
    }

    var messages: [Message] = []
    var interrupts: [Message] = []

    var allMessages: [Message] {
        (messages + interrupts)
            .sorted { $0.timestamp > $1.timestamp }
            .sorted { $0.status.sortPriority < $1.status.sortPriority }
    }

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
                case .processing:
                    self.currentRecordingStatus = .processing
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
                self?.isPlayingAudio = isPlaying
            }
            .store(in: &cancellables)

        realtimeAPI.lastPromptSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prompt in
                guard !prompt.isEmpty else { return }
                self?.addMessage(prompt)
            }
            .store(in: &cancellables)

        logger.promptStatusSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] statusUpdate in
                let messageStatus: MessageStatus
                switch statusUpdate.status {
                case "sent":
                    messageStatus = .sent
                case "injected":
                    messageStatus = .injected
                case "failed":
                    messageStatus = .failed
                default:
                    messageStatus = .notSent
                }
                self?.updateMessageStatus(statusUpdate.prompt, status: messageStatus)

                if statusUpdate.prompt == INTERRUPT_MESSAGE && messageStatus == .injected {
                    self?.removePendingInterrupts()
                }
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


    func addMessage(_ content: String) {
        if let index = messages.firstIndex(where: { $0.status != .injected }) {
            messages[index].content = content
            log("📝 Replaced message content (status: \(messages[index].status)) - \(content)")
        } else {
            let message = Message(
                content: content,
                timestamp: Date(),
                status: .notSent
            )
            messages.insert(message, at: 0)

            log("📝 Created new message (all previous are injected)")
        }
    }

    func updateMessageStatus(_ prompt: String, status: MessageStatus) {
        if let index = messages.firstIndex(where: { $0.content == prompt }) {
            messages[index].status = status
            return
        }
        if let index = interrupts.firstIndex(where: { $0.content == prompt }) {
            interrupts[index].status = status
        }
    }

    func sendMessage(_ content: String) {
        log("📤 Manually sending message: \(content)")
        logger.sendPromptToMac(content)
    }

    func deleteMessage(_ id: UUID) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            let message = messages[index]

            if index == 0 && message.status != .injected {
                realtimeAPI.clearAccumulatedPrompts()
                log("🗑️ Deleted current message and cleared accumulated prompts")
            } else {
                log("🗑️ Deleted message")
            }

            messages.remove(at: index)
            return
        }

        if let index = interrupts.firstIndex(where: { $0.id == id }) {
            interrupts.remove(at: index)
            log("🗑️ Deleted interrupt signal")
        }
    }

    func addInterrupt() {
        let interrupt = Message(
            content: INTERRUPT_MESSAGE,
            timestamp: Date(),
            status: .notSent
        )
        interrupts.insert(interrupt, at: 0)

        log("🛑 Added interrupt signal to conversation")
    }

    func removePendingInterrupts() {
        let removedCount = interrupts.filter { $0.status != .injected }.count
        interrupts.removeAll { $0.status != .injected }
        log("🗑️ Removed \(removedCount) pending interrupt(s) after successful interrupt execution")
    }

    func stopClaudeCode() {
        log("🛑 Adding stop signal to conversation")

        addInterrupt()

        logger.sendPromptToMac(INTERRUPT_MESSAGE)
    }

    deinit {
        stopMotionDetection()
    }

    func stopMotionDetection() {
        motionManager.stopDeviceMotionUpdates()
    }
}
