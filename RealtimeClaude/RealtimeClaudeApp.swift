import SwiftUI
import Combine
import Observation
import CoreMotion

@main
struct RealtimeClaudeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .rotationEffect(Angle(degrees: 180))
                .statusBarHidden()
        }
    }
}

struct ContentView: View {
    @State private var showLogs = true

    var body: some View {
        ZStack {
            WorkView()
                .ignoresSafeArea()
            if showLogs {
                LogListView(showLogs: $showLogs)
                    .ignoresSafeArea()
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        withAnimation(.spring()) {
                            showLogs.toggle()
                        }
                    }) {
                        Image(systemName: showLogs ? "waveform" : "list.bullet")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .padding()
                }
                Spacer()
            }
        }
    }
}

struct WorkView: View {
    @State private var viewModel = WorkViewModel()

    var body: some View {
        ZStack {
            VStack(spacing: 30) {
                VStack(spacing: 8) {
                    Text("Microphone: \(viewModel.isMicrophoneEnabled ? "ON" : "OFF")")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(viewModel.isMicrophoneEnabled ? .green : .gray)

                    Text("Playing: \(viewModel.isPlayingAudio ? "YES" : "NO")")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(viewModel.isPlayingAudio ? .blue : .gray)
                }

                if !viewModel.lastPrompt.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Last Prompt:")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text(viewModel.lastPrompt)
                            .font(.body)
                            .foregroundColor(.primary)
                            .padding()
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(10)
                    }
                    .padding(.horizontal, 20)
                }

                VStack(spacing: 20) {
                    Toggle(isOn: $viewModel.microphoneOverride) {
                        Text("Microphone Override")
                            .font(.headline)
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .green))
                    .padding(.horizontal, 40)

                    Toggle(isOn: $viewModel.playbackEnabled) {
                        Text("Playback Enabled")
                            .font(.headline)
                    }
                    .toggleStyle(SwitchToggleStyle(tint: .blue))
                    .padding(.horizontal, 40)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Pitch: \(Int(viewModel.pitch * 180 / .pi))°")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                        Text("Roll: \(Int(viewModel.roll * 180 / .pi))°")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding()
                }
            }
        }
        .background(Color.black)
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
    var isMicrophoneEnabled = true
    var isPlayingAudio = false
    var lastPrompt = ""
    var pitch: Double = 0
    var roll: Double = 0
    var microphoneOverride = false {
        didSet {
            handleMicrophoneOverrideChange()
        }
    }
    var playbackEnabled = false {
        didSet {
            handlePlaybackChange()
        }
    }
    private var microphoneCancellable: AnyCancellable?
    private var playingCancellable: AnyCancellable?
    private var promptCancellable: AnyCancellable?
    private let motionManager = CMMotionManager()
    private var isFirstMotionUpdate = true

    init() {
        microphoneCancellable = RealtimeAPI.shared.microphoneEnabledSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEnabled in
                self?.isMicrophoneEnabled = isEnabled
            }

        playingCancellable = RealtimeAPI.shared.playingAudioSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPlaying in
                self?.isPlayingAudio = isPlaying
            }

        promptCancellable = RealtimeAPI.shared.lastPromptSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prompt in
                self?.lastPrompt = prompt
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
                        debugLog(id: "tilt", message: "Initial: Device tilted down > 45° (\(Int(pitchDegrees))°) - enabling microphone")
                        log("Device tilted down > 45 degrees - enabling microphone")
                        RealtimeAPI.shared.enableMicrophone()
                        self.isFirstMotionUpdate = false
                    } else {
                        debugLog(id: "tilt", message: "Initial: Device not tilted (\(Int(pitchDegrees))°) - microphone disabled")
                    }
                } else {
                    if pitchDegrees < -45 && !self.isMicrophoneEnabled {
                        debugLog(id: "tilt", message: "Device tilted down > 45° (\(Int(pitchDegrees))°) - enabling microphone")
                        log("Device tilted down > 45 degrees - enabling microphone")
                        RealtimeAPI.shared.enableMicrophone()
                    } else if pitchDegrees > -45 && self.isMicrophoneEnabled {
                        debugLog(id: "tilt", message: "Device tilted back < 45° (\(Int(pitchDegrees))°) - disabling microphone")
                        log("Device tilted back - disabling microphone")
                        RealtimeAPI.shared.disableMicrophone()
                    } else if pitchDegrees < -45 && self.isMicrophoneEnabled {
                        debugLog(id: "tilt", message: "Device still tilted (\(Int(pitchDegrees))°) - microphone remains enabled")
                    } else {
                        debugLog(id: "tilt", message: "Device still not tilted (\(Int(pitchDegrees))°) - microphone remains disabled")
                    }
                }
            } else {
                debugLog(id: "tilt", message: "Tilt detection disabled - microphone override is ON")
            }
        }
    }

    func stopMotionDetection() {
        motionManager.stopDeviceMotionUpdates()
    }

    func handleMicrophoneOverrideChange() {
        if microphoneOverride {
            log("Microphone override ON - enabling microphone manually")
            RealtimeAPI.shared.enableMicrophone()
        } else {
            log("Microphone override OFF - disabling microphone, tilt detection active")
            RealtimeAPI.shared.disableMicrophone()
        }
    }

    func handlePlaybackChange() {
        if playbackEnabled {
            log("Playback enabled")
            RealtimeAPI.shared.enablePlayback()
        } else {
            log("Playback disabled")
            RealtimeAPI.shared.disablePlayback()
        }
    }

    deinit {
        stopMotionDetection()
    }
}
