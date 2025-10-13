/*
# AudioManager - Complete Specification

## Protocol: AudioManagerProtocol (Sendable)
- microphoneEnabledSubject: CurrentValueSubject<Bool, Never>
- playingAudioSubject: CurrentValueSubject<Bool, Never>
- startAudioEngine() throws
- stopAudioEngine()
- enableMicrophone()
- disableMicrophone()
- enablePlayback()
- disablePlayback()
- scheduleOutputAudioBuffer(String)

## Global Variable
- audioManager: AudioManagerProtocol = AudioManager()

## Class: AudioManager (final, @unchecked Sendable)

### Constants
- microphoneEnabledSubject: CurrentValueSubject<Bool, Never> = CurrentValueSubject(false) → installInputAudioTap(): true, removeInputAudioTap(): false
- playingAudioSubject: CurrentValueSubject<Bool, Never> = CurrentValueSubject(false) → scheduleAudio() completion: true if count>0, false if count==0
- audioEngine: AVAudioEngine
- responsePlayerNode: AVAudioPlayerNode
- audioConverter: AVAudioConverter
- OPENAI_AUDIO_FORMAT: AVAudioFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000.0, channels: 1, interleaved: false)

### Properties
- isPlaybackEnabled: Bool = true → enablePlayback(): true, disablePlayback(): false
- scheduledBufferCount: Int = 0 → scheduleOutputAudioBuffer(): ++, completion: --

### Functions
- init() → AVAudioEngine(), AVAudioPlayerNode(), AVAudioFormat(), AVAudioConverter(), attach(), requestMicrophonePermission()
- requestMicrophonePermission() → AVAudioApplication.requestRecordPermission()
- startAudioEngine() → audioEngine.start()
- stopAudioEngine() → audioEngine.stop()
- enableMicrophone() → installInputAudioTap()
- disableMicrophone() → removeInputAudioTap(), if isPlaybackEnabled: responsePlayerNode.play()
- enablePlayback() → isPlaybackEnabled=true
- disablePlayback() → responsePlayerNode.stop(), isPlaybackEnabled=false
- scheduleOutputAudioBuffer(audioBase64) → Data(), AVAudioPCMBuffer(), responsePlayerNode.scheduleBuffer(completion: scheduledBufferCount--, if micEnabled: responsePlayerNode.stop(), if count>0: if already true: debugLog("already playing"), else: send(true) + log("Started playing"), if count==0: send(false) + log("Stopped playing")), scheduledBufferCount++, if count==1 && isPlaybackEnabled && !micEnabled && !playingAudioSubject.value: responsePlayerNode.play()
- convertToOpenAIFormat(buffer) → AVAudioPCMBuffer(), audioConverter.convert()
- bufferToData(buffer) → stride(), Data()
- installInputAudioTap() → inputNode.installTap(→ convertToOpenAIFormat(), bufferToData(), realtimeAPI.processInputAudioBuffer()), microphoneEnabledSubject.send(true)
- removeInputAudioTap() → inputNode.removeTap(), microphoneEnabledSubject.send(false)
*/

import Foundation
@preconcurrency import AVFoundation
import Combine

protocol AudioManagerProtocol: Sendable {
    var microphoneEnabledSubject: CurrentValueSubject<Bool, Never> { get }
    var playingAudioSubject: CurrentValueSubject<Bool, Never> { get }

    func startAudioEngine() throws
    func stopAudioEngine()
    func enableMicrophone()
    func disableMicrophone()
    func enablePlayback()
    func disablePlayback()
    func scheduleOutputAudioBuffer(_ audioBase64: String)
}

nonisolated(unsafe) let audioManager: AudioManagerProtocol = AudioManager()

final class AudioManager: @unchecked Sendable, AudioManagerProtocol {
    let microphoneEnabledSubject = CurrentValueSubject<Bool, Never>(false)
    let playingAudioSubject = CurrentValueSubject<Bool, Never>(false)

    private let audioEngine: AVAudioEngine
    private let responsePlayerNode: AVAudioPlayerNode
    private let audioConverter: AVAudioConverter
    private let OPENAI_AUDIO_FORMAT = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: false)!

    private var isPlaybackEnabled: Bool = true
    private var scheduledBufferCount: Int = 0

    init() {
        audioEngine = AVAudioEngine()

        let inputFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        audioConverter = AVAudioConverter(from: inputFormat, to: OPENAI_AUDIO_FORMAT)!

        responsePlayerNode = AVAudioPlayerNode()
        audioEngine.attach(responsePlayerNode)
        audioEngine.connect(responsePlayerNode, to: audioEngine.mainMixerNode, format: OPENAI_AUDIO_FORMAT)

        requestMicrophonePermission()
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

    func startAudioEngine() throws {
        try audioEngine.start()
        log("Audio engine started successfully")
    }

    func stopAudioEngine() {
        audioEngine.stop()
        log("Audio engine stopped")
    }

    func enableMicrophone() {
        if microphoneEnabledSubject.value {
            debugLog(id: "enableMicrophone", message: "⚠️ [Audio] Microphone already enabled, ignoring")
            return
        }
        responsePlayerNode.stop()
        installInputAudioTap()
        log("Microphone enabled")
    }

    func disableMicrophone() {
        removeInputAudioTap()

        if isPlaybackEnabled {
            responsePlayerNode.play()
        }

        log("Microphone disabled")
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

    func scheduleOutputAudioBuffer(_ audioBase64: String) {
        if microphoneEnabledSubject.value {
            log("🎤 Microphone enabled - stopping playback to prevent audio interference")
            responsePlayerNode.stop()
            return
        }

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

        responsePlayerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self = self else {
                error("audioManager deallocated during audio playback")
                return
            }

            self.scheduledBufferCount -= 1

            if self.microphoneEnabledSubject.value {
                self.responsePlayerNode.stop()
            }

            if self.scheduledBufferCount > 0 {
                if self.playingAudioSubject.value {
                    debugLog(id: "audioPlayback", message: "🎵 [Audio] Already playing")
                } else {
                    self.playingAudioSubject.send(true)
                    log("Started playing response")
                }
            } else if self.scheduledBufferCount == 0 {
                self.playingAudioSubject.send(false)
                log("Stopped playing response")
            }
        }

        scheduledBufferCount += 1

        if scheduledBufferCount == 1 && isPlaybackEnabled && !microphoneEnabledSubject.value && !playingAudioSubject.value {
            responsePlayerNode.play()
        }
    }

    func createPCMBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameLength = UInt32(data.count / MemoryLayout<Int16>.size)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }

        buffer.frameLength = frameLength

        let audioBuffer = buffer.int16ChannelData![0]
        data.withUnsafeBytes { bytes in
            audioBuffer.initialize(from: bytes.bindMemory(to: Int16.self).baseAddress!, count: Int(frameLength))
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

            if self.microphoneEnabledSubject.value {
                guard let convertedBuffer = self.convertToOpenAIFormat(buffer) else {
                    return
                }

                guard let data = self.bufferToData(convertedBuffer) else {
                    return
                }

                realtimeAPI.processInputAudioBuffer(data)
            } else {
                debugLog(id: "inputAudio", message: "⛔ [Audio] Microphone disabled, ignoring buffer")
            }
        }

        microphoneEnabledSubject.send(true)
        log("Audio tap installed")
    }

    func removeInputAudioTap() {
        audioEngine.inputNode.removeTap(onBus: 0)
        microphoneEnabledSubject.send(false)
        log("Audio tap uninstalled")
    }
}
