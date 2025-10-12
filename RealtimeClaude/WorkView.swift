/*
# REFACTORING DOCUMENT: WorkView.swift

## Current State: ✅ PROPERLY ORDERED

### Enum: MessageStatus

#### Computed Properties:
Line 15: color: Color (public, get-only) → uses: self
Line 27: statusText: String (public, get-only) → uses: self

### Struct: Message (Identifiable)

#### Constants:
- id: UUID (public, let) = UUID()
- timestamp: Date (public, let) = passed at initialization

#### Properties:
- content: String (public, var) = passed at initialization
- status: MessageStatus (public, var) = passed at initialization → mutated in: updateMessageStatus(= new status)

### Struct: ToggleBar (View)

#### Struct: ToggleItem

#### Constants:
- color: Color (public, let) = passed from parent
- icon: String? (public, let) = passed from parent
- text: String? (public, let) = passed from parent
- action: () -> Void (public, let) = passed from parent

#### Properties:
- isOn: Bool (public, @Binding var) → mutated in: user toggle (binding from parent)

#### Constants:
- items: [ToggleItem] (public, let) = passed from parent
- height: CGFloat (public, let) = 120 (default)
- topSpacing: CGFloat (public, let) = 20 (default)
- yOffset: CGFloat (public, let) = 60 (default)

#### Functions:
Line 65: init(items:height:topSpacing:yOffset:) | (leaf)

#### Computed Properties:
Line 72: body: some View (public, get-only) → uses: items, height, topSpacing, yOffset

### Struct: WorkView (View)

#### Properties:
- viewModel: WorkViewModel (private, @State var) = WorkViewModel() → mutated in: SwiftUI state management
- showLogs: Bool (public, @Binding var) → mutated in: toggle action (binding from parent)

#### Computed Properties:
Line 119: body: some View (public, get-only) → uses: viewModel, showLogs
  → log: "Log view shown"
  → log: "Log view hidden"

### Class: WorkViewModel (@Observable)

#### Properties:
- isMicrophoneEnabled: Bool (public, var) = true → mutated in: init subscription(= from realtimeAPI.microphoneEnabledSubject)
- isPlayingAudio: Bool (public, var) = false → mutated in: init subscription(= from realtimeAPI.playingAudioSubject)
- messages: [Message] (public, var) = [] → mutated in: addMessage(insert message at 0)
- pitch: Double (public, var) = 0 → mutated in: startMotionDetection(= attitude.pitch)
- roll: Double (public, var) = 0 → mutated in: startMotionDetection(= attitude.roll)
- microphoneCancellable: AnyCancellable? (private, var) = nil → mutated in: init(= subscription)
- playingCancellable: AnyCancellable? (private, var) = nil → mutated in: init(= subscription)
- promptCancellable: AnyCancellable? (private, var) = nil → mutated in: init(= subscription)
- statusCancellable: AnyCancellable? (private, var) = nil → mutated in: init(= subscription)
- voiceStartedCancellable: AnyCancellable? (private, var) = nil → mutated in: init(= subscription)
- voiceStoppedCancellable: AnyCancellable? (private, var) = nil → mutated in: init(= subscription)
- functionStartedCancellable: AnyCancellable? (private, var) = nil → mutated in: init(= subscription)
- motionManager: CMMotionManager (private, let) = CMMotionManager()
- isFirstMotionUpdate: Bool (private, var) = true → mutated in: startMotionDetection(= false when mic enabled)
- currentRecordingId: UUID? (public, var) = nil → mutated in: handleVoiceStarted(= UUID()), addMessage(= nil)
- currentRecordingStatus: MessageStatus? (public, var) = nil → mutated in: handleVoiceStarted(= .recording), handleVoiceStopped(= .stopped), handleFunctionStarted(= .processing), addMessage(= nil)
- currentRecordingTimestamp: Date? (public, var) = nil → mutated in: handleVoiceStarted(= Date()), addMessage(= nil)

#### Properties (with didSet):
Line 252: microphoneOverride: Bool (public, var) = false → mutated in: user toggle, didSet calls handleMicrophoneOverrideChange()
Line 257: playbackEnabled: Bool (public, var) = true → mutated in: user toggle, didSet calls handlePlaybackChange()

#### Functions:
Line 415: init() → realtimeAPI.microphoneEnabledSubject.sink(), realtimeAPI.playingAudioSubject.sink(), realtimeAPI.lastPromptSubject.sink(), logger.promptStatusSubject.sink(), realtimeAPI.voiceActivityStartedSubject.sink(), realtimeAPI.voiceActivityStoppedSubject.sink(), realtimeAPI.functionExecutionStartedSubject.sink(), addMessage(), updateMessageStatus()

Line 471: startMotionDetection() → motionManager.startDeviceMotionUpdates(), realtimeAPI.enableMicrophone(), realtimeAPI.disableMicrophone()
  → log: "Device motion not available"
  → log: "Device tilted down > 45 degrees - enabling microphone"
  → log: "Device tilted back - disabling microphone"
  → debug: "📱 [Motion] Initial tilt detected: \(Int(pitchDegrees))° (enabling mic)"
  → debug: "📱 [Motion] Initial position: \(Int(pitchDegrees))° (mic disabled)"
  → debug: "📱 [Motion] Tilted down: \(Int(pitchDegrees))° (enabling mic)"
  → debug: "📱 [Motion] Tilted back: \(Int(pitchDegrees))° (disabling mic)"
  → debug: "📱 [Motion] Still tilted: \(Int(pitchDegrees))° (mic enabled)"
  → debug: "📱 [Motion] Still upright: \(Int(pitchDegrees))° (mic disabled)"
  → debug: "⛔ [Motion] Tilt detection disabled (override ON)"

Line 525: handleMicrophoneOverrideChange() → realtimeAPI.enableMicrophone(), realtimeAPI.disableMicrophone()
  → log: "Microphone override ON - enabling microphone manually"
  → log: "Microphone override OFF - disabling microphone, tilt detection active"

Line 535: handlePlaybackChange() → realtimeAPI.enablePlayback(), realtimeAPI.disablePlayback()
  → log: "Playback enabled"
  → log: "Playback disabled"

Line 545: handleVoiceStarted(_:) | (leaf)

Line 551: handleVoiceStopped(_:) | (leaf)

Line 555: handleFunctionStarted(_:) | (leaf)

Line 559: addMessage(_:) → messages.firstIndex(), messages.insert()
  → log: "📝 Replaced message content (status: \(messages[index].status))"
  → log: "📝 New content: \(content)"
  → log: "📝 Created new message (all previous are injected)"

Line 585: updateMessageStatus(_:status:) → messages.firstIndex()

Line 591: deleteMessage(_:) → messages.firstIndex(), realtimeAPI.clearAccumulatedPrompts(), messages.remove()
  → log: "🗑️ Deleted current message and cleared accumulated prompts"
  → log: "⚠️ Cannot delete successfully injected message"
  → log: "⚠️ Can only delete the current (first) message"

Line 608: deinit() → stopMotionDetection()

Line 612: stopMotionDetection() → motionManager.stopDeviceMotionUpdates()
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
    let yOffset: CGFloat

    init(items: [ToggleItem], height: CGFloat = CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_TOP")) * 2, topSpacing: CGFloat = CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_TOP")) / 3, yOffset: CGFloat = -CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_BOTTOM"))) {
        self.items = items
        self.height = height
        self.topSpacing = topSpacing
        self.yOffset = yOffset
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
        .offset(y: yOffset)
    }
}

struct WorkView: View {
    @State private var viewModel = WorkViewModel()
    @Binding var showLogs: Bool

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack {
                if viewModel.allMessages.isEmpty {
                    Spacer()
                    Text("Speak to create a message")
                        .font(.headline)
                        .foregroundColor(.gray)
                    Spacer()
                } else {
                    ScrollViewReader { proxy in
                        List {
                            Color.clear
                                .frame(height: 60)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets())
                                .id("topSpacer")

                            ForEach(viewModel.allMessages) { message in
                                ZStack(alignment: .bottomTrailing) {
                                    if message.content == INTERRUPT_MESSAGE {
                                        // Special display for interrupt messages
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
                                .listRowSeparator(.visible)
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
                        }
                        .listStyle(PlainListStyle())
                        .scrollContentBackground(.hidden)
                        .environment(\.defaultMinListRowHeight, 0)
                        .frame(height: {
                            let screenHeight = CGFloat(UserDefaults.standard.double(forKey: "SCREEN_HEIGHT"))
                            let safeTop = CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_TOP"))
                            let safeBottom = CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_BOTTOM"))
                            // Height = screen height + safe area top + safe area bottom
                            return screenHeight + safeTop + safeBottom
                        }())
                        .offset(y: -CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_BOTTOM")))
                        .onChange(of: viewModel.allMessages.count) { _ in
                            withAnimation {
                                proxy.scrollTo("topSpacer", anchor: .top)
                            }
                        }
                    }
                }
            }
            .ignoresSafeArea()
            .frame(maxHeight: .infinity)

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
                    .offset(y: -34)

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

                // Map API state to recording status
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

        microphoneCancellable = realtimeAPI.microphoneEnabledSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEnabled in
                guard let self = self else { return }
                self.isMicrophoneEnabled = isEnabled
                // Update status if we're in connected state
                if self.currentRecordingStatus == .connected || self.currentRecordingStatus == .microphoneEnabled {
                    self.currentRecordingStatus = isEnabled ? .microphoneEnabled : .connected
                }
            }

        playingCancellable = realtimeAPI.playingAudioSubject
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
                        realtimeAPI.enableMicrophone()
                        self.isFirstMotionUpdate = false
                    } else {
                        debugLog(id: "deviceTilt", message: "📱 [Motion] Initial position: \(Int(pitchDegrees))° (mic disabled)")
                    }
                } else {
                    if pitchDegrees < -45 && !self.isMicrophoneEnabled {
                        debugLog(id: "deviceTilt", message: "📱 [Motion] Tilted down: \(Int(pitchDegrees))° (enabling mic)")
                        log("Device tilted down > 45 degrees - enabling microphone")
                        realtimeAPI.enableMicrophone()
                    } else if pitchDegrees > -45 && self.isMicrophoneEnabled {
                        debugLog(id: "deviceTilt", message: "📱 [Motion] Tilted back: \(Int(pitchDegrees))° (disabling mic)")
                        log("Device tilted back - disabling microphone")
                        realtimeAPI.disableMicrophone()
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
            realtimeAPI.enableMicrophone()
        } else {
            log("Microphone override OFF - disabling microphone, tilt detection active")
            realtimeAPI.disableMicrophone()
        }
    }

    func handlePlaybackChange() {
        if playbackEnabled {
            log("Playback enabled")
            realtimeAPI.enablePlayback()
        } else {
            log("Playback disabled")
            realtimeAPI.disablePlayback()
        }
    }


    func addMessage(_ content: String) {
        if let index = messages.firstIndex(where: { $0.status != .injected }) {
            messages[index].content = content

            log("📝 Replaced message content (status: \(messages[index].status))")
            log("📝 New content: \(content)")
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

        // Send it to Mac for injection like a regular prompt
        logger.sendPromptToMac(INTERRUPT_MESSAGE)
    }

    deinit {
        stopMotionDetection()
    }

    func stopMotionDetection() {
        motionManager.stopDeviceMotionUpdates()
    }
}
