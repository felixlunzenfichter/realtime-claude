import Foundation
@preconcurrency import AVFoundation
import Combine

protocol AudioManagerProtocol: Sendable {
    var isRecordingAudioSubject: CurrentValueSubject<Bool, Never> { get }
    var isPlayingAudioSubject: CurrentValueSubject<Bool, Never> { get }
    var audioInputSourceSubject: CurrentValueSubject<String, Never> { get }
    var isPlaybackEnabledSubject: CurrentValueSubject<Bool, Never> { get }
    var currentPlayingMessageIdSubject: CurrentValueSubject<UUID?, Never> { get }

    func startRecording(messageId: UUID)
    func stopRecording()
    func enablePlayback()
    func disablePlayback()
    func play(audio: Data, id: UUID)
    func reset()
}

nonisolated(unsafe) let audioManager: AudioManagerProtocol = AudioManager()

final class AudioManager: @unchecked Sendable, AudioManagerProtocol {
    let isRecordingAudioSubject = CurrentValueSubject<Bool, Never>(false)
    let isPlayingAudioSubject = CurrentValueSubject<Bool, Never>(false)
    let audioInputSourceSubject = CurrentValueSubject<String, Never>("Unknown")
    let isPlaybackEnabledSubject = CurrentValueSubject<Bool, Never>(true)
    let currentPlayingMessageIdSubject = CurrentValueSubject<UUID?, Never>(nil)

    private let audioEngine: AVAudioEngine
    private let responsePlayerNode: AVAudioPlayerNode
    private let audioConverter: AVAudioConverter
    private let WHISPER_AUDIO_FORMAT = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
    private let TTS_OUTPUT_FORMAT = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false)!

    private var scheduledBufferCount: Int = 0
    private var buffersPlayedCount: Int = 0
    private var currentMessageId: UUID?
    private var playQueue: [(id: UUID, audio: Data)] = []
    private let queueLock = DispatchQueue(label: "com.realtimeclaude.audioqueue", attributes: .concurrent)

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

        do {
            try audioEngine.start()
            log("Audio engine started successfully in init")
        } catch {
            log("Failed to start audio engine in init: \(error.localizedDescription)")
        }
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

    private var isFirstAudioPacket: Bool = false

    func startRecording(messageId: UUID) {
        if isRecordingAudioSubject.value {
            debugLog(id: "startRecording", message: "⚠️ [Audio] Already recording, ignoring")
            return
        }
        currentMessageId = messageId
        isRecordingAudioSubject.send(true)
        responsePlayerNode.stop()
        isFirstAudioPacket = true
        installInputAudioTap()
        log("Started recording with message ID: \(messageId)")
    }

    func stopRecording() {
        audioEngine.inputNode.removeTap(onBus: 0)

        isRecordingAudioSubject.send(false)
        log("Stopped recording")

        logger.sendAudioToMac(Data(), isStart: false, isEnd: true, messageId: currentMessageId)
        currentMessageId = nil

        responsePlayerNode.reset()

        queueLock.sync(flags: .barrier) {
            playQueue.removeAll()
        }

        playNext()
    }

    func enablePlayback() {
        isPlaybackEnabledSubject.send(true)
        log("Playback enabled")
    }

    func disablePlayback() {
        isPlaybackEnabledSubject.send(false)
        responsePlayerNode.stop()
        currentPlayingMessageIdSubject.send(nil)
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
        currentPlayingMessageIdSubject.send(nil)

        log("Audio manager reset complete")
    }

    func play(audio: Data, id: UUID) {
        guard isPlaybackEnabledSubject.value else {
            log("Playback disabled, skipping audio")
            return
        }

        let queueSize = queueLock.sync(flags: .barrier) {
            playQueue.append((id: id, audio: audio))
            return playQueue.count
        }
        let shouldStartPlaying = currentPlayingMessageIdSubject.value == nil && !isRecordingAudioSubject.value

        log("Added audio to queue for message: \(id), queue size: \(queueSize)")

        if shouldStartPlaying {
            playNext()
        }
    }

    private func playNext() {
        guard !isRecordingAudioSubject.value else { return }

        let item = queueLock.sync(flags: .barrier) { () -> (id: UUID, audio: Data)? in
            guard !playQueue.isEmpty else {
                return nil
            }
            return playQueue.removeFirst()
        }

        guard let item = item else {
            log("Play queue empty")
            return
        }

        log("Playing next audio for message: \(item.id)")

        currentPlayingMessageIdSubject.send(item.id)
        isPlayingAudioSubject.send(true)


        guard let buffer = createPCMBuffer(from: item.audio, format: TTS_OUTPUT_FORMAT) else {
            error("Failed to create PCM buffer from audio data")
            playbackFinished()
            return
        }

        responsePlayerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self = self else {
                error("audioManager deallocated during audio playback")
                return
            }

            DispatchQueue.main.async {
                self.playbackFinished()
            }
        }
                if !responsePlayerNode.isPlaying {
            responsePlayerNode.play()
        }

    }

    private func playbackFinished() {
        log("Playback finished")
        currentPlayingMessageIdSubject.send(nil)
        isPlayingAudioSubject.send(false)
        playNext()
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

            logger.sendAudioToMac(data, isStart: isStart, isEnd: false, messageId: self.currentMessageId)

            guard let int16Buffer = self.convertToWhisperFormat(buffer) else {
                return
            }
            guard let int16Data = self.bufferToData(int16Buffer) else {
                return
            }
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
