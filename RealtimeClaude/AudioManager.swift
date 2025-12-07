import Foundation
@preconcurrency import AVFoundation
import Combine

protocol AudioManagerProtocol: Sendable {
    var isRecordingAudioSubject: CurrentValueSubject<Bool, Never> { get }
    var isPlayingAudioSubject: CurrentValueSubject<Bool, Never> { get }
    var audioInputSourceSubject: CurrentValueSubject<String, Never> { get }
    var isPlaybackEnabledSubject: CurrentValueSubject<Bool, Never> { get }

    func startAudioEngine()
    func stopAudioEngine()
    func startRecording()
    func stopRecording()
    func getIsPlaybackEnabled() -> Bool
    func enablePlayback()
    func disablePlayback()
    func scheduleOutputAudioBuffer(_ audioBase64: String, resetCount: Bool, onBufferPlayed: ((Int) -> Void)?)
    func reset()
}

nonisolated(unsafe) let audioManager: AudioManagerProtocol = AudioManager()

final class AudioManager: @unchecked Sendable, AudioManagerProtocol {
    let isRecordingAudioSubject = CurrentValueSubject<Bool, Never>(false)
    let isPlayingAudioSubject = CurrentValueSubject<Bool, Never>(false)
    let audioInputSourceSubject = CurrentValueSubject<String, Never>("Unknown")
    let isPlaybackEnabledSubject = CurrentValueSubject<Bool, Never>(true)

    private let audioEngine: AVAudioEngine
    private let responsePlayerNode: AVAudioPlayerNode
    private let audioConverter: AVAudioConverter
    private let WHISPER_AUDIO_FORMAT = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
    private let TTS_OUTPUT_FORMAT = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false)!

    private var isPlaybackEnabled: Bool = true
    private var scheduledBufferCount: Int = 0
    private var buffersPlayedCount: Int = 0

    init() {
        // Configure audio session ONCE at init - never touch it again
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)
            log("Audio session configured: playAndRecord with defaultToSpeaker + Bluetooth A2DP output")
        } catch {
            log("Failed to configure audio session: \(error.localizedDescription)")
        }

        audioEngine = AVAudioEngine()

        let inputFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        audioConverter = AVAudioConverter(from: inputFormat, to: WHISPER_AUDIO_FORMAT)!

        responsePlayerNode = AVAudioPlayerNode()
        audioEngine.attach(responsePlayerNode)
        audioEngine.connect(responsePlayerNode, to: audioEngine.mainMixerNode, format: TTS_OUTPUT_FORMAT)

        requestMicrophonePermission()
        updateAudioInputSource()
    }

    deinit {
        audioEngine.stop()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            log("Audio session deactivated")
        } catch {
            log("Failed to deactivate audio session: \(error.localizedDescription)")
        }
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
        DispatchQueue.main.async {
            do {

                try self.audioEngine.start()
                self.updateAudioInputSource()
                log("Audio engine started successfully with speaker output")
            } catch let startError {
                error("Failed to start audio engine: \(startError.localizedDescription)")
            }
        }
    }

    func stopAudioEngine() {
        DispatchQueue.main.async {
            self.audioEngine.stop()
        }
    }

    private var isFirstAudioPacket: Bool = false

    func startRecording() {
        if isRecordingAudioSubject.value {
            debugLog(id: "startRecording", message: "⚠️ [Audio] Already recording, ignoring")
            return
        }
        isRecordingAudioSubject.send(true)
        responsePlayerNode.stop()
        isFirstAudioPacket = true
        installInputAudioTap()
        log("Started recording")
    }

    func stopRecording() {
        audioEngine.inputNode.removeTap(onBus: 0)

        isRecordingAudioSubject.send(false)
        log("Stopped recording")

        logger.sendAudioToMac(Data(), isStart: false, isEnd: true)

        responsePlayerNode.reset()
        responsePlayerNode.play()
    }

    func getIsPlaybackEnabled() -> Bool {
        return isPlaybackEnabled
    }

    func enablePlayback() {
        isPlaybackEnabled = true
        isPlaybackEnabledSubject.send(true)
        log("Playback enabled")
    }

    func disablePlayback() {
        isPlaybackEnabled = false
        isPlaybackEnabledSubject.send(false)
        responsePlayerNode.stop()
        log("Playback disabled")
    }

    func reset() {
        log("Resetting audio manager")

        if isRecordingAudioSubject.value {
            audioEngine.inputNode.removeTap(onBus: 0)
            isRecordingAudioSubject.send(false)
        }

        responsePlayerNode.stop()
        responsePlayerNode.reset()

        scheduledBufferCount = 0
        buffersPlayedCount = 0

        isPlayingAudioSubject.send(false)

        log("Audio manager reset complete")
    }

    func scheduleOutputAudioBuffer(_ audioBase64: String, resetCount: Bool, onBufferPlayed: ((Int) -> Void)?) {
        if !isPlaybackEnabled {
            debugLog(id: "scheduleAudio", message: "⛔ [Audio] Playback disabled, skipping audio")
            return
        }

        guard let audioData = Data(base64Encoded: audioBase64) else {
            error("Failed to decode response audio data")
            return
        }

        guard let buffer = createPCMBuffer(from: audioData, format: TTS_OUTPUT_FORMAT) else {
            error("Failed to create PCM buffer from response audio")
            return
        }

        responsePlayerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self = self else {
                error("audioManager deallocated during audio playback")
                return
            }

            DispatchQueue.main.async {
                if resetCount {
                    self.buffersPlayedCount = 0
                }

                self.scheduledBufferCount -= 1
                self.buffersPlayedCount += 1

                onBufferPlayed?(self.buffersPlayedCount)

                if self.scheduledBufferCount > 0 {
                    if self.isPlayingAudioSubject.value {
                        debugLog(id: "audioPlayback", message: "🎵 [Audio] Already playing")
                    } else {
                        self.isPlayingAudioSubject.send(true)
                        log("Started playing response")
                    }
                } else if self.scheduledBufferCount == 0 {
                    self.isPlayingAudioSubject.send(false)
                    log("Stopped playing response")
                }
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

    func convertToWhisperFormat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / buffer.format.sampleRate)

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
            guard let self = self else {
                error("audioManager deallocated during audio tap")
                return
            }

            guard let convertedBuffer = self.convertToFloat32Format(buffer) else {
                error("Failed to convert audio buffer to float32 format")
                return
            }

            guard let data = self.bufferToFloat32Data(convertedBuffer) else {
                error("Failed to convert audio buffer to data")
                return
            }

            let isStart = self.isFirstAudioPacket
            if self.isFirstAudioPacket {
                self.isFirstAudioPacket = false
            }

            logger.sendAudioToMac(data, isStart: isStart, isEnd: false)

            guard let int16Buffer = self.convertToWhisperFormat(buffer) else {
                return
            }
            guard let int16Data = self.bufferToData(int16Buffer) else {
                return
            }
            realtimeAPI.processInputAudioBuffer(int16Data)
        }

        log("Audio tap installed - streaming to Mac with VAD")
    }

    func convertToFloat32Format(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let float32Format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / buffer.format.sampleRate)

        guard let converter = AVAudioConverter(from: buffer.format, to: float32Format) else {
            error("Failed to create float32 audio converter")
            return nil
        }

        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: float32Format, frameCapacity: outputFrameCapacity) else {
            error("Failed to create converted buffer")
            return nil
        }

        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        var converterError: NSError? = nil
        let status = converter.convert(to: convertedBuffer, error: &converterError, withInputFrom: inputBlock)

        if let converterError = converterError {
            error("Audio conversion failed: \(converterError.localizedDescription)")
            return nil
        }

        return status == .haveData ? convertedBuffer : nil
    }

    func bufferToFloat32Data(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.floatChannelData?[0] else {
            error("Failed to get float channel data")
            return nil
        }

        let frameLength = Int(buffer.frameLength)
        let data = Data(bytes: channelData, count: frameLength * MemoryLayout<Float>.size)
        return data
    }
}
