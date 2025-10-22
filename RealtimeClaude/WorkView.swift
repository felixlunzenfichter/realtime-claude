/*
# WorkView - Complete Specification

## Global Constant
- INTERRUPT_MESSAGE: String = "[Request interrupted by user]"

## Enum: RecordingStatus
- cases: disconnected, connected, microphoneEnabled, speechDetected, speechStopped, processing

### Computed Properties
- color: Color → uses: self
- statusText: String → uses: self

## Enum: MessageStatus
- cases: recording, stopped, processing, notSent, sent, injected, failed

### Computed Properties
- color: Color → uses: self
- statusText: String → uses: self

## Struct: Message (Identifiable)

### Constants
- id: UUID = UUID()
- timestamp: Date

### Properties
- content: String → addMessage(): =
- status: MessageStatus → updateMessageStatus(): =

## Struct: ToggleBar (View)

### Nested Struct: ToggleItem
- color: Color
- isOn: Binding<Bool>?
- icon: String?
- text: String?
- action: () -> Void

### Properties
- items: [ToggleItem]
- height: CGFloat = UserDefaults("SAFE_AREA_TOP") * 2
- topSpacing: CGFloat = UserDefaults("SAFE_AREA_TOP") / 3
- yOffset: CGFloat = -UserDefaults("SAFE_AREA_BOTTOM")

### Functions
- init(items, height, topSpacing, yOffset) → (leaf)

### Computed Properties
- body: some View → HStack with ForEach(items), Rectangle.fill(), Toggle/Image/Text overlays, frame(height), glassEffect(), offset(yOffset)

## Struct: WorkView (View)

### Properties
- viewModel: WorkViewModel (@State) = WorkViewModel()
- showLogs: Bool (@Binding)

### Computed Properties
- ACTUAL_SCREEN_HEIGHT: CGFloat → UserDefaults("SCREEN_HEIGHT") + UserDefaults("SAFE_AREA_TOP") + UserDefaults("SAFE_AREA_BOTTOM")
- body: some View → ZStack: Color.black, VStack with message list/empty state, ToggleBar at bottom, status text at top

## Class: WorkViewModel (@Observable)

### Constants
- motionManager: CMMotionManager = CMMotionManager()

### Properties
- currentRecordingId: UUID?
- currentRecordingStatus: RecordingStatus = .disconnected → init apiStateCancellable: =
- currentRecordingTimestamp: Date?
- isMicrophoneEnabled: Bool = false → init microphoneCancellable: =
- isPlayingAudio: Bool = false → init playingCancellable: =
- messages: [Message] = [] → addMessage(): insert/update, deleteMessage(): remove
- interrupts: [Message] = [] → addInterrupt(): insert
- microphoneOverride: Bool = false (didSet: handleMicrophoneOverrideChange())
- pitch: Double = 0 → startMotionDetection(): =
- playbackEnabled: Bool = true (didSet: handlePlaybackChange())
- roll: Double = 0 → startMotionDetection(): =
- apiStateCancellable: AnyCancellable? → init: =
- isFirstMotionUpdate: Bool = true → startMotionDetection(): false
- microphoneCancellable: AnyCancellable? → init: =
- playingCancellable: AnyCancellable? → init: =
- promptCancellable: AnyCancellable? → init: =
- statusCancellable: AnyCancellable? → init: =

### Computed Properties
- allMessages: [Message] → messages + interrupts sorted by timestamp descending

### Functions
- init() → realtimeAPI.apiStateSubject.sink(), audioManager.microphoneEnabledSubject.sink(), audioManager.playingAudioSubject.sink(), realtimeAPI.lastPromptSubject.sink(), logger.promptStatusSubject.sink()
- startMotionDetection() → motionManager.startDeviceMotionUpdates(), pitch=, roll=, if !microphoneOverride: if tilt<-45: audioManager.enableMicrophone(), else: audioManager.disableMicrophone()
- handleMicrophoneOverrideChange() → if microphoneOverride: audioManager.enableMicrophone(), else: audioManager.disableMicrophone()
- handlePlaybackChange() → if playbackEnabled: audioManager.enablePlayback(), else: audioManager.disablePlayback()
- addMessage(content) → if exists non-injected: messages[index].content=, else: messages.insert(at: 0)
- updateMessageStatus(prompt, status) → messages.firstIndex() or interrupts.firstIndex(), status=
- deleteMessage(id) → if index==0 && status!=.injected: realtimeAPI.clearAccumulatedPrompts(), messages.remove()
- addInterrupt() → interrupts.insert(Message(INTERRUPT_MESSAGE, .notSent), at: 0)
- stopClaudeCode() → addInterrupt(), logger.sendPromptToMac(INTERRUPT_MESSAGE)
- stopMotionDetection() → motionManager.stopDeviceMotionUpdates()
- deinit() → stopMotionDetection()
*/

import SwiftUI
import Combine
import Observation
import CoreMotion

let INTERRUPT_MESSAGE = "[Request interrupted by user]"

enum RecordingStatus {
    case disconnected
    case connected
    case microphoneEnabled
    case speechDetected
    case speechStopped
    case processing

    var color: Color {
        switch self {
        case .disconnected: return .red
        case .connected: return .blue
        case .microphoneEnabled: return .green
        case .speechDetected: return .yellow
        case .speechStopped: return .orange
        case .processing: return .purple
        }
    }

    var statusText: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connected: return "Connected"
        case .microphoneEnabled: return "Recording"
        case .speechDetected: return "Voice Activity Detected"
        case .speechStopped: return "Voice Activity Stopped"
        case .processing: return "Processing..."
        }
    }
}

enum MessageStatus {
    case recording
    case stopped
    case processing
    case notSent
    case sent
    case injected
    case failed

    var color: Color {
        switch self {
        case .recording: return .white
        case .stopped: return .white
        case .processing: return .white
        case .notSent: return .white
        case .sent: return .orange
        case .injected: return .green
        case .failed: return .red
        }
    }

    var statusText: String {
        switch self {
        case .recording: return "Recording..."
        case .stopped: return "Recording stopped"
        case .processing: return "Processing..."
        case .notSent: return ""
        case .sent: return "Sending..."
        case .injected: return ""
        case .failed: return "Failed ✗"
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
    let topSpacing: CGFloat

    init(items: [ToggleItem], height: CGFloat = CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_TOP")) * 2, topSpacing: CGFloat = CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_TOP")) / 3) {
        self.items = items
        self.height = height
        self.topSpacing = topSpacing
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                Rectangle()
                    .fill(item.color.opacity(0.1))
                    .overlay(
                        VStack {
                            Spacer()
                                .frame(height: topSpacing)
                            HStack(spacing: 8) {
                                if let isOn = item.isOn {
                                    Toggle(isOn: isOn) {
                                        EmptyView()
                                    }
                                    .toggleStyle(SwitchToggleStyle(tint: item.color))
                                    .labelsHidden()
                                }

                                if let icon = item.icon {
                                    Image(systemName: icon)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(item.color)
                                }

                                if let text = item.text {
                                    Text(text)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(item.color)
                                }
                            }
                            Spacer()
                        }
                    )
                    .onTapGesture {
                        item.action()
                    }
            }
        }
        .frame(height: height)
        .glassEffect()
    }
}

struct WorkView: View {
    @State private var viewModel = WorkViewModel()
    @Binding var showLogs: Bool

    var body: some View {
        ZStack {
            if viewModel.allMessages.isEmpty {
                VStack {
                    Spacer()
                    Text("Speak to create a message")
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
                        isOn: $viewModel.playbackEnabled,
                        icon: viewModel.isPlayingAudio ? "speaker.wave.3.fill" : "speaker.slash.fill",
                        action: {
                            viewModel.playbackEnabled.toggle()
                        }
                    ),
                    ToggleBar.ToggleItem(
                        color: .green,
                        isOn: $viewModel.microphoneOverride,
                        icon: viewModel.isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill",
                        action: {
                            viewModel.microphoneOverride.toggle()
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

            VStack {
                Text(viewModel.currentRecordingStatus.statusText)
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 60)
                    .background(viewModel.currentRecordingStatus.color)
                    .glassEffect()

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
    private let motionManager = CMMotionManager()

    var currentRecordingId: UUID?
    var currentRecordingStatus: RecordingStatus = .disconnected
    var currentRecordingTimestamp: Date?
    var isMicrophoneEnabled = false
    var isPlayingAudio = false
    var messages: [Message] = []
    var interrupts: [Message] = []

    var allMessages: [Message] {
        (messages + interrupts).sorted { $0.timestamp > $1.timestamp }
    }
    var microphoneOverride = false {
        didSet {
            handleMicrophoneOverrideChange()
        }
    }
    var pitch: Double = 0
    var playbackEnabled = true {
        didSet {
            handlePlaybackChange()
        }
    }
    var roll: Double = 0

    private var apiStateCancellable: AnyCancellable?
    private var isFirstMotionUpdate = true
    private var microphoneCancellable: AnyCancellable?
    private var playingCancellable: AnyCancellable?
    private var promptCancellable: AnyCancellable?
    private var statusCancellable: AnyCancellable?

    init() {
        apiStateCancellable = realtimeAPI.apiStateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] apiState in
                guard let self = self else { return }

                switch apiState {
                case .disconnected:
                    self.currentRecordingStatus = .disconnected
                case .connected:
                    self.currentRecordingStatus = self.isMicrophoneEnabled ? .microphoneEnabled : .connected
                case .speechDetected:
                    self.currentRecordingStatus = .speechDetected
                    self.currentRecordingId = UUID()
                    self.currentRecordingTimestamp = Date()
                case .speechStopped:
                    self.currentRecordingStatus = .speechStopped
                case .processing:
                    self.currentRecordingStatus = .processing
                }
            }

        microphoneCancellable = audioManager.microphoneEnabledSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEnabled in
                guard let self = self else { return }
                self.isMicrophoneEnabled = isEnabled
                if self.currentRecordingStatus == .connected || self.currentRecordingStatus == .microphoneEnabled {
                    self.currentRecordingStatus = isEnabled ? .microphoneEnabled : .connected
                }
            }

        playingCancellable = audioManager.playingAudioSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPlaying in
                self?.isPlayingAudio = isPlaying
            }

        promptCancellable = realtimeAPI.lastPromptSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prompt in
                guard !prompt.isEmpty else { return }
                self?.addMessage(prompt)
            }

        statusCancellable = logger.promptStatusSubject
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
            }
    }

    func startMotionDetection() {
        guard motionManager.isDeviceMotionAvailable else {
            log("Device motion not available")
            return
        }

        motionManager.deviceMotionUpdateInterval = 1
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] data, error in
            guard let self = self,
                  let attitude = data?.attitude else { return }

            self.pitch = attitude.pitch
            self.roll = attitude.roll

            let pitchDegrees = attitude.pitch * (180 / .pi)

            if !self.microphoneOverride {
                if self.isFirstMotionUpdate {
                    if pitchDegrees < -45 {
                        debugLog(id: "deviceTilt", message: "📱 [Motion] Initial tilt detected: \(Int(pitchDegrees))° (enabling mic)")
                        log("Device tilted down > 45 degrees - enabling microphone")
                        audioManager.enableMicrophone()
                        self.isFirstMotionUpdate = false
                    } else {
                        debugLog(id: "deviceTilt", message: "📱 [Motion] Initial position: \(Int(pitchDegrees))° (mic disabled)")
                    }
                } else {
                    if pitchDegrees < -45 && !self.isMicrophoneEnabled {
                        debugLog(id: "deviceTilt", message: "📱 [Motion] Tilted down: \(Int(pitchDegrees))° (enabling mic)")
                        log("Device tilted down > 45 degrees - enabling microphone")
                        audioManager.enableMicrophone()
                    } else if pitchDegrees > -45 && self.isMicrophoneEnabled {
                        debugLog(id: "deviceTilt", message: "📱 [Motion] Tilted back: \(Int(pitchDegrees))° (disabling mic)")
                        log("Device tilted back - disabling microphone")
                        audioManager.disableMicrophone()
                        let currentPrompt = realtimeAPI.lastPromptSubject.value
                        if !currentPrompt.isEmpty {
                            log("Sending prompt to Claude Code: \(currentPrompt)")
                            logger.sendPromptToMac(currentPrompt)
                        }
                    } else if pitchDegrees < -45 && self.isMicrophoneEnabled {
                        debugLog(id: "deviceTilt", message: "📱 [Motion] Still tilted: \(Int(pitchDegrees))° (mic enabled)")
                    } else {
                        debugLog(id: "deviceTilt", message: "📱 [Motion] Still upright: \(Int(pitchDegrees))° (mic disabled)")
                    }
                }
            } else {
                debugLog(id: "deviceTilt", message: "⛔ [Motion] Tilt detection disabled (override ON)")
            }
        }
    }

    func handleMicrophoneOverrideChange() {
        if microphoneOverride {
            log("Microphone override ON - enabling microphone manually")
            audioManager.enableMicrophone()
        } else {
            log("Microphone override OFF - disabling microphone, tilt detection active")
            audioManager.disableMicrophone()
            let currentPrompt = realtimeAPI.lastPromptSubject.value
            if !currentPrompt.isEmpty {
                log("Sending prompt to Claude Code: \(currentPrompt)")
                logger.sendPromptToMac(currentPrompt)
            }
        }
    }

    func handlePlaybackChange() {
        if playbackEnabled {
            log("Playback enabled")
            audioManager.enablePlayback()
        } else {
            log("Playback disabled")
            audioManager.disablePlayback()
        }
    }


    func addMessage(_ content: String) {
        if let index = messages.firstIndex(where: { $0.status != .injected }) {
            let existingContent = messages[index].content

            if content.hasPrefix(existingContent) {
                messages[index].content = content
                log("🔄 Replaced prefix: existing message was contained in new content - \(content)")
            } else if existingContent.contains(content) {
                log("⏭️ Skipped duplicate: content already in message")
            } else if existingContent != content {
                messages[index].content = content
                log("📝 Replaced message content (status: \(messages[index].status)) - \(content)")
            }
        } else {
            let message = Message(
                content: content,
                timestamp: currentRecordingTimestamp ?? Date(),
                status: .notSent
            )
            messages.insert(message, at: 0)

            log("📝 Created new message (all previous are injected)")
        }

        currentRecordingId = nil
        currentRecordingTimestamp = nil
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

    func deleteMessage(_ id: UUID) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            let message = messages[index]

            if index == 0 && message.status != .injected {
                realtimeAPI.clearAccumulatedPrompts()

                messages.remove(at: index)
                log("🗑️ Deleted current message and cleared accumulated prompts")
            } else if message.status == .injected {
                log("⚠️ Cannot delete successfully injected message")
            } else {
                log("⚠️ Can only delete the current (first) message")
            }
            return
        }

        if interrupts.firstIndex(where: { $0.id == id }) != nil {
            log("⚠️ Cannot delete interrupt signals")
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
