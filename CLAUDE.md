# CLAUDE.md

## System Information
- **Current Date: September 26, 2025**
- **iOS 26** (Release Date: September 15, 2025)
- **iPadOS 26** (Release Date: September 15, 2025)
- **macOS 26 Tahoe** (Release Date: September 15, 2025)
- **Xcode 18** (Release Date: September 2025)
- **WhisperKit Version**: v0.15.0 (November 2024, latest stable)
- Note: Apple changed numbering to unify all OS versions at "26" for 2025-2026 season

## Core Principles

**100% dogfood. The app must never crash.**

- NEVER use `!` or `try!` - always use safe unwrapping
- Use `guard let` or `if let` for all optionals
- When something is nil or errors occur: use `error()` to log it
- Pattern: `guard let x = y else { error("y was nil"); return }`
- Why: We want fast builds without debug symbols but still get proper error logs
- After the error has been successfully transmitted to Mac, we will automatically restart the app
- Use `error()` heavily in any case that would usually generate a crash

Always debug mode, always direct install. This is our tool.

## TDD Development

Each task = 3 commits:
1. Write test (test file is located in: scripts/test-system.js)
2. Make test pass (minimal code only, ignore refactoring rules)
3. Refactor & clean up (apply refactoring rules)

### Implementation Rules (Step 2)
- Focus on making test pass quickly
- Comment heavily mentioning resources, documentation links, API references
- Include TODO comments for things to clean up in refactoring
- Document any assumptions or gotchas discovered
- Make heavy use of log() and error() functions (see Logger.swift for usage)
- Log all successes and especially catch ALL errors with error()

### Refactoring Rules (Step 3)
- Apply ONLY after test passes
- Function ordering: If function A uses function B, then B must be defined below A
- Function ordering: If function A is used before function B, then A should be defined before B
- Functions should be small, do one thing, and have descriptive names
- NO COMMENTS in code - zero tolerance for any comments, express yourself only in logs
- Clean up any TODO items from implementation phase
- Code should read like well-written prose

## WhisperKit Transcription (CRITICAL)

**This is the core of the app. Speech-to-text must work fast.**

### Current Architecture
- **STT (Speech-to-Text)**: WhisperKit with `openai_whisper-large-v3_turbo` model, on-device
- **TTS (Text-to-Speech)**: OpenAI API (cloud)
- **Model Repository**: `argmaxinc/whisperkit-coreml` on HuggingFace

### Whisper Large-v3-Turbo Model

The `openai_whisper-large-v3_turbo` is a pruned and finetuned version of Whisper large-v3:

| Property | Large-v3 | Large-v3-Turbo |
|----------|----------|----------------|
| Parameters | 1550M | 809M |
| Decoder Layers | 32 | 4 |
| VRAM Required | ~10 GB | ~6 GB |
| Speed | Baseline | 3-7x faster |
| WER (accuracy) | 7.88% | 7.75% |

**Key insight**: Turbo has only 4 decoder layers (same as tiny model) but keeps the full 32-layer encoder, giving near-identical accuracy at much higher speed.

**Limitation**: Turbo is NOT trained for translation tasks (non-English to English). Use large-v3 if translation is needed.

### Available Model Variants

| Model | WER | Size | Notes |
|-------|-----|------|-------|
| openai_whisper-large-v3_turbo | 2.41% | 3100 MB | Full quality, recommended |
| openai_whisper-large-v3_turbo_1307MB | 2.6% | 1307 MB | Mixed-bit quantization |
| openai_whisper-large-v3_turbo_1049MB | 4.81% | 1049 MB | Compressed |
| openai_whisper-large-v3-v20240930_turbo_632MB | N/A | 632 MB | 4-bit with outlier decomposition |

### Expected Performance

#### iPhone 17 Pro Max (A19 Pro)
- **Speed Factor**: 7-10x real-time
- **Latency**: ~0.45 seconds per word (hypothesis text)
- **GPU improvement**: 2.5-3.1x faster than iPhone 16 Pro
- **Neural Engine improvement**: 1-1.15x faster than iPhone 16 Pro

#### iPad Pro M4
- **Speed Factor**: 8-12x real-time (better thermal headroom)
- **Neural Engine**: 38 TOPS (vs 18 TOPS on M3, 111% improvement)
- **Sustained performance**: Better than iPhone due to larger thermal envelope

#### M2 Ultra (Mac)
- **Speed Factor**: 42x real-time (ANE only), up to 72x (GPU+ANE)

### Benchmark Comparisons (from WhisperKit paper, July 2025)

| System | Latency (hypothesis) | WER | Notes |
|--------|---------------------|-----|-------|
| WhisperKit | 0.45-0.46s | 2.0-2.2% | Best accuracy |
| Fireworks large-v3-turbo | 0.45s | 4.72% | Cloud |
| Deepgram nova-3 | 0.83s | 2.0% | Cloud |
| OpenAI gpt-4o-transcribe | Similar | 2.4% | Cloud |

**WhisperKit matches lowest latency while achieving highest accuracy.**

### DecodingOptions for MAXIMUM SPEED

```swift
DecodingOptions(
    verbose: false,
    task: .transcribe,
    language: nil,              // Auto-detect (or "en" for English-only = ~10-15% faster)
    temperature: 0.0,           // Greedy decoding - FASTEST, deterministic
    temperatureFallbackCount: 0, // No retries - FASTER
    sampleLength: 224,          // Limit output length
    usePrefillPrompt: false,    // Don't use prompt - FASTER
    usePrefillCache: true,      // CRITICAL: 45% latency reduction via KV cache
    skipSpecialTokens: true,
    withoutTimestamps: true,    // Skip timestamps - FASTER
    clipTimestamps: []
)
```

### ModelComputeOptions for Neural Engine

```swift
ModelComputeOptions(
    melCompute: .cpuAndNeuralEngine,
    audioEncoderCompute: .cpuAndNeuralEngine,  // Encoder on ANE = 6x faster than CPU
    textDecoderCompute: .cpuAndNeuralEngine,   // Decoder on ANE = 3x faster
    prefillCompute: .cpuAndNeuralEngine
)
```

**Available compute units:**
- `.cpuOnly` - CPU only
- `.cpuAndGPU` - CPU + GPU
- `.cpuAndNeuralEngine` - RECOMMENDED for best speed/efficiency
- `.all` - All available

### Key Speed Factors (ranked by impact)

1. **usePrefillCache = true** - 45% latency reduction (8.4ms → 4.6ms per decoder pass)
2. **audioEncoderCompute = .cpuAndNeuralEngine** - 6x faster than CPU-only
3. **temperature = 0.0 + temperatureFallbackCount = 0** - Eliminates retry loops
4. **withoutTimestamps = true** - Skips timestamp calculation overhead
5. **language = "en"** (if known) - Skips language detection (~10-15% faster)

### KV Cache Technical Details

WhisperKit uses Apple's Core ML **Stateful Models** feature:
- Key-value cache is read and updated **in-place**
- Cache **persists across forward passes** without tensor copying
- Provides **75% energy reduction** (1.5W → 0.3W per forward pass)
- Critical for on-device deployment (battery life, thermal management)

### WhisperKit Optimizations (from ICML 2025 paper)

1. **Block-Diagonal Attention Masking (d750)**
   - 65% latency reduction in encoder (612ms → 218ms)
   - WER regression under 1%
   - Enables "silence caching" for zero-padded audio

2. **Silence Caching**
   - Pre-computed encoder outputs for zero-padded segments
   - Cached at compile time, eliminates redundant computations

3. **Outlier-Decomposed Mixed-Bit Palettization (OD-MBP)**
   - Compresses model from 1.6 GB to 0.6 GB
   - WER remains within 1% of original

4. **LocalAgreement Streaming Policy**
   - Dual output: confirmed text (stable, ~1.7s) + hypothesis text (fast, ~0.45s)
   - Confirms text by finding longest common prefix across consecutive hypotheses

### Streaming with AudioStreamTranscriber

For real-time streaming (v0.6.0+):

```swift
let streamTranscriber = AudioStreamTranscriber(
    audioProcessor: whisperKit.audioProcessor,
    transcriber: whisperKit,
    decodingOptions: decodingOptions,
    requiredSegmentsForConfirmation: 2,  // Consecutive matches before confirming
    silenceThreshold: 0.3,               // VAD sensitivity (0.0-1.0)
    compressionCheckWindow: 20,          // Detect repetitive outputs
    useVAD: true,                        // Enable Voice Activity Detection
    stateChangeCallback: { state in
        // Handle streaming state changes
    }
)
```

### Common Problems & Solutions

| Problem | Cause | Solution |
|---------|-------|----------|
| 0.3x RTF (slower than real-time) | `usePrefillCache: false` | Set to `true` |
| 0.3x RTF | Multiple transcriptions competing | Serialize transcription calls |
| 0.3x RTF | Not using Neural Engine | Check `ModelComputeOptions` |
| First transcription very slow (4-6 min) | ANE compilation on first run | Normal, cached after first run |
| Periodic slowdowns | iOS cleared ANE cache (storage pressure) | Model recompiles, nothing to do |
| High latency with correct settings | Wrong audio format | Must be 16kHz mono Float32/Int16 |

### Audio Format Requirements

- **Sample Rate**: 16 kHz (REQUIRED)
- **Channels**: Mono
- **Format**: Float32 PCM (or Int16 converted to Float)

Conversion from Int16 to Float:
```swift
let samples = audioData.withUnsafeBytes { buffer -> [Float] in
    let int16Buffer = buffer.bindMemory(to: Int16.self)
    return int16Buffer.map { Float($0) / Float(Int16.max) }
}
```

### Hardware Specifications

#### A19 Pro (iPhone 17 Pro Max)
- **Process**: TSMC N3P (3nm)
- **CPU**: 6-core (2 performance @ 4.26 GHz + 4 efficiency @ 2.60 GHz)
- **GPU**: 6-core Apple10 (96 execution units, 768 ALUs)
- **Neural Engine**: 16-core
- **Memory**: 12GB LPDDR5X @ 76.8 GB/s
- **New**: Neural Accelerators in GPU (4x peak ML compute vs A18 Pro)
- **Cooling**: Vapor chamber enables 40% better sustained performance

#### M4 (iPad Pro)
- **Neural Engine**: 38 TOPS (vs 18 TOPS on M3)
- **Advantage**: Larger thermal envelope = better sustained performance

### WhisperKit Version History

- **v0.15.0** (Nov 2024): `TranscriptionResult` changed to open class, swift-transformers 1.1.2
- **v0.14.1** (Oct 2024): Swift 6 concurrency support, `Sendable` conformance
- **v0.14.0** (Sep 2024): Local Server with OpenAI-compatible API, SSE streaming
- **v0.13.1**: Tokenizer fixes, offline loading support
- **v0.13.0** (Jun 2024): Async VAD, segments discovery callback

### Sources

- [WhisperKit GitHub](https://github.com/argmaxinc/WhisperKit)
- [WhisperKit Paper (ICML 2025)](https://arxiv.org/html/2507.10860v1)
- [WhisperKit Benchmarks](https://huggingface.co/spaces/argmaxinc/whisperkit-benchmarks)
- [Argmax Blog - WhisperKit](https://www.argmaxinc.com/blog/whisperkit)
- [Argmax Blog - iPhone 17 Benchmarks](https://www.argmaxinc.com/blog/iphone-17-on-device-inference-benchmarks)
- [Argmax Blog - Apple SpeechAnalyzer Comparison](https://www.argmaxinc.com/blog/apple-and-argmax)
- [WhisperKit CoreML Models](https://huggingface.co/argmaxinc/whisperkit-coreml)
- [Whisper Large-v3-Turbo on HuggingFace](https://huggingface.co/openai/whisper-large-v3-turbo)
- [Apple Core ML Stateful Models](https://apple.github.io/coremltools/docs-guides/source/stateful-models.html)
- [WhisperKit Swift Package Index](https://swiftpackageindex.com/argmaxinc/WhisperKit)

## Run

### ONLY Safe Deployment Method

**ALWAYS use deploy-in-window.sh:**

```bash
./scripts/deploy-in-window.sh
```

This switches to a separate Terminal window for deployment. This is the ONLY safe way to deploy.

### CRITICAL: Why deploy.sh MUST NEVER Be Run Directly

**NEVER run `deploy.sh` directly in ANY form** - not in foreground, not in background, not with `run_in_background: true`.

**Why this kills the server:**
- When Claude Code context is interrupted (conversation ends, context limit hit, etc.), any background processes started by the main agent are terminated
- Running `deploy.sh` in background means the build/deploy process dies when Claude Code stops
- This kills the running server on the device mid-deployment
- Result: Broken deployment, orphaned processes, corrupted state

**The ONLY safe method is `deploy-in-window.sh`** because:
- Launches in a completely separate Terminal window/process
- Process is independent of Claude Code's lifecycle
- Server keeps running even if Claude Code conversation ends
- Build completes successfully regardless of context interruptions

After making any code changes, always deploy to test on device using `deploy-in-window.sh`.
