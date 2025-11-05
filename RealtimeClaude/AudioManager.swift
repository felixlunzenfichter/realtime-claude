import Foundation
@preconcurrency import AVFoundation
import Combine

protocol AudioManagerProtocol: Sendable {
    var isRecordingAudioSubject: CurrentValueSubject<Bool, Never> { get }
    var isPlayingAudioSubject: CurrentValueSubject<Bool, Never> { get }
    var audioInputSourceSubject: CurrentValueSubject<String, Never> { get }

    func startAudioEngine()
    func stopAudioEngine()
    func startRecording()
    func stopRecording()
    func enablePlayback()
    func disablePlayback()
    func scheduleOutputAudioBuffer(_ audioBase64: String, onBufferPlayed: ((Int) -> Void)?)
}

nonisolated(unsafe) let audioManager: AudioManagerProtocol = AudioManager()

final class AudioManager: @unchecked Sendable, AudioManagerProtocol {
    let isRecordingAudioSubject = CurrentValueSubject<Bool, Never>(false)
    let isPlayingAudioSubject = CurrentValueSubject<Bool, Never>(false)
    let audioInputSourceSubject = CurrentValueSubject<String, Never>("Unknown")

    private let audioEngine: AVAudioEngine
    private let responsePlayerNode: AVAudioPlayerNode
    private let audioConverter: AVAudioConverter
    private let OPENAI_AUDIO_FORMAT = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false)!

    private var isPlaybackEnabled: Bool = true
    private var scheduledBufferCount: Int = 0
    private var buffersPlayedCount: Int = 0

    init() {
        audioEngine = AVAudioEngine()

        let inputFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        audioConverter = AVAudioConverter(from: inputFormat, to: OPENAI_AUDIO_FORMAT)!

        responsePlayerNode = AVAudioPlayerNode()
        audioEngine.attach(responsePlayerNode)
        audioEngine.connect(responsePlayerNode, to: audioEngine.mainMixerNode, format: OPENAI_AUDIO_FORMAT)

        requestMicrophonePermission()
        updateAudioInputSource()
    }

    func requestMicrophonePermission() {
        log("Requesting microphone permission...")
        Task {
            let granted = await AVAudioApplication.requestRecordPermission()
            if granted {
                log("Microphone permission granted")
            } else {
                error("Microphone permission denied - cannot proceed")
            }
        }
    }

    func updateAudioInputSource() {
        let session = AVAudioSession.sharedInstance()
        let inputSource = session.currentRoute.inputs.first?.portName ?? "Unknown"
        audioInputSourceSubject.send(inputSource)
        log("Audio input source: \(inputSource)")
    }

    func startAudioEngine() {
        do {
            try audioEngine.start()
            updateAudioInputSource()
            log("Audio engine started successfully")
        } catch let startError {
            error("Failed to start audio engine: \(startError.localizedDescription)")
        }
    }

    func stopAudioEngine() {
        audioEngine.stop()
        log("Audio engine stopped")
    }

    func startRecording() {
        if isRecordingAudioSubject.value {
            debugLog(id: "startRecording", message: "⚠️ [Audio] Already recording, ignoring")
            return
        }
        responsePlayerNode.stop()
        installInputAudioTap()
        log("Started recording")
    }

    func stopRecording() {
        audioEngine.inputNode.removeTap(onBus: 0)

        isRecordingAudioSubject.send(false)
        log("Stopped recording")

        responsePlayerNode.play()
        sendSilence()
    }

    private func sendSilence() {
        guard realtimeAPI.apiStateSubject.value == .speechDetected else {
            log("Speech stopped detected, stopping silence")
            return
        }

        realtimeAPI.processInputAudioBuffer(generateSilenceBuffer(durationMs: 100))

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.sendSilence()
        }
    }

    private func generateSilenceBuffer(durationMs: Int) -> Data {
        let sampleRate = 24000
        let numSamples = (sampleRate * durationMs) / 1000
        var silenceBuffer = [Int16](repeating: 0, count: numSamples)
        let data = Data(bytes: &silenceBuffer, count: silenceBuffer.count * MemoryLayout<Int16>.size)
        return data
    }

    func enablePlayback() {
        isPlaybackEnabled = true
        log("Playback enabled")
    }

    func disablePlayback() {
        isPlaybackEnabled = false
        responsePlayerNode.stop()
        log("Playback disabled")
    }

    func scheduleOutputAudioBuffer(_ audioBase64: String, onBufferPlayed: ((Int) -> Void)?) {
        if !isPlaybackEnabled {
            debugLog(id: "scheduleAudio", message: "⛔ [Audio] Playback disabled, skipping audio")
            return
        }

        guard let audioData = Data(base64Encoded: audioBase64) else {
            error("Failed to decode response audio data")
            return
        }

        guard let buffer = createPCMBuffer(from: audioData, format: OPENAI_AUDIO_FORMAT) else {
            error("Failed to create PCM buffer from response audio")
            return
        }

        if scheduledBufferCount == 0 {
            buffersPlayedCount = 0
        }

        responsePlayerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self = self else {
                error("audioManager deallocated during audio playback")
                return
            }

            self.scheduledBufferCount -= 1
            self.buffersPlayedCount += 1

            onBufferPlayed?(self.buffersPlayedCount)

            if self.isRecordingAudioSubject.value {
                self.responsePlayerNode.stop()
                log("🎤 Stopped response player node because microphone is active")
            }

            if self.scheduledBufferCount > 0 {
                if self.isPlayingAudioSubject.value {
                    debugLog(id: "audioPlayback", message: "🎵 [Audio] Already playing")
                } else {
                    self.isPlayingAudioSubject.send(true)
                    log("Started playing response")
                }
            } else if self.scheduledBufferCount == 0 {
                self.isPlayingAudioSubject.send(false)
                self.buffersPlayedCount = 0
                log("Stopped playing response")
            }
        }

        scheduledBufferCount += 1

        if scheduledBufferCount == 1 && isPlaybackEnabled && !isRecordingAudioSubject.value && !isPlayingAudioSubject.value {
            responsePlayerNode.play()
        }
    }

    func createPCMBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameLength = UInt32(data.count / MemoryLayout<Int16>.size)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }

        buffer.frameLength = frameLength

        guard let audioBuffer = buffer.int16ChannelData?[0] else {
            error("Failed to get int16 channel data from PCM buffer")
            return nil
        }

        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.bindMemory(to: Int16.self).baseAddress else {
                error("Failed to get base address from audio data bytes")
                return
            }
            audioBuffer.initialize(from: baseAddress, count: Int(frameLength))
        }

        return buffer
    }

    func convertToOpenAIFormat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * 24000.0 / buffer.format.sampleRate)

        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: audioConverter.outputFormat, frameCapacity: outputFrameCapacity) else {
            error("Failed to create converted buffer")
            return nil
        }

        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        var converterError: NSError? = nil
        let status = audioConverter.convert(to: convertedBuffer, error: &converterError, withInputFrom: inputBlock)

        if let converterError = converterError {
            error("Audio conversion failed: \(converterError.localizedDescription)")
            return nil
        }

        return status == .haveData ? convertedBuffer : nil
    }

    func bufferToData(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.int16ChannelData?[0] else {
            error("Failed to get channel data")
            return nil
        }

        let frameLength = Int(buffer.frameLength)
        let data = Data(bytes: channelData, count: frameLength * MemoryLayout<Int16>.size)
        return data
    }

    func installInputAudioTap() {
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }

            if !self.isRecordingAudioSubject.value {
                self.isRecordingAudioSubject.send(true)
            }

            guard let convertedBuffer = self.convertToOpenAIFormat(buffer) else {
                return
            }

            guard let data = self.bufferToData(convertedBuffer) else {
                return
            }

            realtimeAPI.processInputAudioBuffer(data)
        }

        log("Audio tap installed")
    }
}
