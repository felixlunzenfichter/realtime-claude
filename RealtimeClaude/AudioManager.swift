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
