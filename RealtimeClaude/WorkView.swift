import SwiftUI
import Combine
import Observation
import CoreMotion

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
    var playbackEnabled = true {
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
        microphoneCancellable = realtimeAPI.microphoneEnabledSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isEnabled in
                self?.isMicrophoneEnabled = isEnabled
            }

        playingCancellable = realtimeAPI.playingAudioSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPlaying in
                self?.isPlayingAudio = isPlaying
            }

        promptCancellable = realtimeAPI.lastPromptSubject
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

    func stopMotionDetection() {
        motionManager.stopDeviceMotionUpdates()
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

    deinit {
        stopMotionDetection()
    }
}