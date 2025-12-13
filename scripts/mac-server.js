const net = require('net');
const fs = require('fs');
const path = require('path');
const { exec, spawn, execSync, spawnSync } = require('child_process');
const chokidar = require('chokidar');
const FormData = require('form-data');
const fetch = require('node-fetch');

process.on('uncaughtException', (error) => {
    console.error(`⚠️ Uncaught exception (continuing): ${error.stack || error}`);
});

process.on('unhandledRejection', (reason, promise) => {
    console.error(`⚠️ Unhandled promise rejection (continuing): ${reason}`);
});

const logsDir = path.join('private', 'logs');
const lastAssistantMessageFile = path.join('private', 'last-assistant-message.txt');
const CLAUDE_WINDOW_PATTERN = 'claude --dangerously-skip-permissions';
const WHISPER_SERVER_URL = 'http://localhost:5050';
let currentSessionFile = null;
let currentSessionNumber = 0;
let activeSocket = null;
let lastSentAssistantMessage = null;
let lastDiffSent = null;
let diffDebounceTimer = null;

const MAX_AUDIO_DURATION = 10;
const MAX_AUDIO_BYTES = MAX_AUDIO_DURATION * 16000 * 4;

const MAX_SUMMARY_CHARS = 100;
const MAX_CONTEXT_EVENTS = 20;

const assistantSummaryCache = [];
const MAX_SUMMARY_CACHE_SIZE = 5;

let haikuContext = [];

const messageStates = new Map();

function getMessageState(messageId) {
    if (!messageId) {
        console.log('⚠️ No messageId provided, using fallback ID');
        messageId = 'fallback';
    }

    if (!messageStates.has(messageId)) {
        console.log(`📋 Creating new message state for ID: ${messageId}`);
        messageStates.set(messageId, {
            messageId: messageId,
            audioBuffer: Buffer.alloc(0),
            isTranscribing: false,
            isRecordingAudio: false,
            transcriptionHistory: [],
            allTranscriptions: [],
            transcriptionCounter: 0
        });
    }

    return messageStates.get(messageId);
}

function cleanupMessageState(messageId) {
    if (messageId && messageStates.has(messageId)) {
        console.log(`🧹 Cleaning up message state for ID: ${messageId}`);
        messageStates.delete(messageId);
    }
}

function addToContext(event) {
    haikuContext.push({
        ...event,
        timestamp: Date.now()
    });
    if (haikuContext.length > MAX_CONTEXT_EVENTS) {
        haikuContext.shift();
    }
    console.log(`📚 Context: ${haikuContext.length} events`);
}

function formatContextForHaiku() {
    if (haikuContext.length === 0) return "No previous context.";

    return haikuContext.map((e, i) => {
        const interimLabel = e.interim ? ' (interim)' : ' (final)';
        switch (e.type) {
            case 'transcription':
                return `[${i + 1}] TRANSCRIPTION${interimLabel}: "${e.text}"`;
            case 'corrected':
                return `[${i + 1}] CORRECTED${interimLabel}: "${e.raw}" → "${e.corrected}"`;
            case 'user_message':
                return `[${i + 1}] USER: "${e.text}" (summary: "${e.summary || 'pending'}")`;
            case 'assistant_message':
                return `[${i + 1}] ASSISTANT: "${e.text.substring(0, 100)}..." (summary: "${e.summary || 'pending'}")`;
            case 'summary_attempt':
                return `[${i + 1}] SUMMARY ${e.success ? 'OK' : 'FAILED'}: "${e.result}" (${e.chars} chars, max ${MAX_SUMMARY_CHARS})`;
            default:
                return `[${i + 1}] ${e.type}: ${JSON.stringify(e).substring(0, 80)}`;
        }
    }).join('\n');
}

async function processWithHaiku(text, task, fullTranscriptions = null) {
    const cleanText = text.replace(/[\n\r]+/g, ' ').replace(/\s+/g, ' ').trim();
    const context = formatContextForHaiku();

    console.log(`🤖 Haiku ${task}: "${cleanText.substring(0, 60)}..."`);

    const MAX_ATTEMPTS = 5;
    let attempt = 0;

    while (attempt < MAX_ATTEMPTS) {
        attempt++;
        try {
            const retryNote = attempt > 1 ? ` (attempt ${attempt}/${MAX_ATTEMPTS})` : '';
            console.log(`   Processing${retryNote}...`);

            const fullTranscriptionsText = fullTranscriptions
                ? `\n\nFULL TRANSCRIPTION HISTORY (all raw outputs from Whisper, no deduplication):\n${fullTranscriptions.map((t, i) => `[${i + 1}] (${t.startTime}s-${t.endTime}s) ${t.text}`).join('\n')}`
                : '';

            let prompt;
            if (task === 'correct_transcription') {
                prompt = `You are a transcription processor for a voice-controlled coding assistant.

CONTEXT (last ${haikuContext.length} events):
${context}${fullTranscriptionsText}

TASK: Correct transcription errors
INPUT (deduplicated version): "${cleanText}"

INSTRUCTIONS:
Fix any speech-to-text errors based on context. Common issues: misheard technical terms, homophones, incomplete words.
${fullTranscriptions ? '\nNOTE: You have both the full transcription history (all raw Whisper outputs) and the deduplicated version. Use the full history for context/safety if needed.' : ''}

OUTPUT: Respond with valid JSON only, no markdown, no explanation:
{"corrected": "the corrected text or original if no correction needed"}`;
            } else {
                prompt = `You are a transcription processor for a voice-controlled coding assistant.

CONTEXT (last ${haikuContext.length} events):
${context}

TASK: Create summary
INPUT: "${cleanText}"

INSTRUCTIONS:
Create a brief summary (under ${MAX_SUMMARY_CHARS} characters) describing what this prompt is asking for.

OUTPUT: Respond with valid JSON only, no markdown, no explanation:
{"summary": "short summary under ${MAX_SUMMARY_CHARS} chars"}`;
            }

            const os = require('os');
            const inputFile = path.join(os.tmpdir(), `claude-input-${Date.now()}-${process.pid}.txt`);
            const outputFile = path.join(os.tmpdir(), `claude-output-${Date.now()}-${process.pid}.txt`);

            try {
                fs.writeFileSync(inputFile, prompt);

                execSync(`cat "${inputFile}" | claude --model haiku --print - > "${outputFile}" 2>/dev/null`, {
                    stdio: 'ignore',
                    shell: '/bin/bash',
                    timeout: 30000
                });

                const result = fs.readFileSync(outputFile, 'utf8').trim();

                if (!result) {
                    throw new Error('claude command returned empty output');
                }

                const cleanedResult = result.replace(/```json\n?/g, '').replace(/```\n?/g, '').trim();

                let parsed;
                try {
                    parsed = JSON.parse(cleanedResult);
                } catch (parseErr) {
                    console.log(`   ⚠️ Invalid JSON: ${cleanedResult.substring(0, 100)}`);
                    addToContext({ type: 'summary_attempt', result: cleanedResult, chars: cleanedResult.length, success: false, error: 'invalid_json' });
                    continue;
                }

                const summary = parsed.summary || '';
                const corrected = parsed.corrected || cleanText;

                if (task === 'correct_transcription') {
                    console.log(`   ✅ Corrected: "${corrected.substring(0, 50)}..."`);
                    return { corrected };
                } else {
                    if (summary.length > MAX_SUMMARY_CHARS) {
                        console.log(`   ⚠️ Summary too long: ${summary.length} chars`);
                        addToContext({ type: 'summary_attempt', result: summary, chars: summary.length, success: false, error: 'too_long' });
                        continue;
                    }
                    console.log(`   ✅ Summary: "${summary}" (${summary.length} chars)`);
                    addToContext({ type: 'summary_attempt', result: summary, chars: summary.length, success: true });
                    return { summary };
                }

            } finally {
                try { fs.unlinkSync(inputFile); } catch {}
                try { fs.unlinkSync(outputFile); } catch {}
            }

        } catch (error) {
            console.error(`   ❌ Haiku failed: ${error.message}`);
            addToContext({ type: 'summary_attempt', result: error.message, chars: 0, success: false, error: 'exception' });
        }
    }

    console.log(`   ⚠️ Max attempts reached, using fallback`);
    if (task === 'correct_transcription') {
        return { corrected: cleanText };
    } else {
        return { summary: cleanText.substring(0, MAX_SUMMARY_CHARS) };
    }
}

async function summarizeWithClaude(text) {
    const result = await processWithHaiku(text, 'create_summary');
    return result.summary;
}

function deduplicateTranscription(newText, messageState) {
    if (!newText || newText.trim().length === 0) {
        return getConcatenatedText(messageState);
    }

    if (messageState.transcriptionHistory.length === 0) {
        console.log(`🔍 First transcription - adding all text: "${newText}"`);
        messageState.transcriptionHistory.push({ text: newText, timestamp: Date.now() });
        return newText;
    }

    const last10 = messageState.transcriptionHistory.slice(-10);
    const wordsSeen = new Set();
    for (const entry of last10) {
        for (const word of entry.text.split(/\s+/)) {
            wordsSeen.add(word.toLowerCase());
        }
    }
    console.log(`🔍 Deduplicating "${newText}" against ${wordsSeen.size} words from last ${last10.length} transcriptions`);

    const newWords = [];
    for (const word of newText.split(/\s+/)) {
        if (!wordsSeen.has(word.toLowerCase())) {
            newWords.push(word);
            console.log(`   ✅ KEEP new word: "${word}"`);
        } else {
            console.log(`   ⏭️  SKIP duplicate: "${word}" - checked against: [${Array.from(wordsSeen).join(', ')}]`);
        }
    }

    const uniqueText = newWords.join(' ').trim();

    if (uniqueText.length > 0) {
        messageState.transcriptionHistory.push({ text: uniqueText, timestamp: Date.now() });
        console.log(`📝 Added to history: "${uniqueText}"`);
    } else {
        console.log(`⏭️  No unique words to add`);
    }

    return getConcatenatedText(messageState);
}

function getConcatenatedText(messageState) {
    return messageState.transcriptionHistory.map(entry => entry.text).join(' ').trim();
}

async function transcribeAudio(audioPath) {
    try {
        const startTime = Date.now();

        const formData = new FormData();
        formData.append('audio', fs.createReadStream(audioPath));

        const response = await fetch(`${WHISPER_SERVER_URL}/transcribe`, {
            method: 'POST',
            body: formData,
            headers: formData.getHeaders()
        });

        if (!response.ok) {
            throw new Error(`Whisper server returned ${response.status}: ${response.statusText}`);
        }

        const result = await response.json();
        const elapsedMs = Date.now() - startTime;

        console.log(`⚡ Lightning Whisper: ${result.elapsed_ms}ms server + ${elapsedMs - result.elapsed_ms}ms network = ${elapsedMs}ms total`);

        return {
            text: result.text,
            segments: result.segments || []
        };
    } catch (error) {
        throw new Error(`Transcription failed: ${error.message}`);
    }
}

async function handleAudioMessage(socket, logData) {
    const { audioData, isStart, isEnd, messageId } = logData;

    if (isStart) {
        console.log('🎤 Audio recording started (embedded flag)');
        const msgId = messageId || 'fallback';
        console.log(`📋 Message ID: ${msgId}`);

        const messageState = getMessageState(msgId);
        messageState.audioBuffer = Buffer.alloc(0);
        messageState.isRecordingAudio = true;
        messageState.transcriptionHistory = [];
        messageState.allTranscriptions = [];
        messageState.transcriptionCounter = 0;
        return;
    }

    if (isEnd) {
        console.log('🎯 FINAL CHUNK: Processing final transcription unconditionally...');
        await triggerTranscription(true, messageId);
        await handleAudioEnd(messageId);
        return;
    }

    if (!audioData) {
        console.log('⚠️ No audio data in message');
        return;
    }

    const msgId = messageId || 'fallback';
    const messageState = getMessageState(msgId);

    const newAudio = Buffer.from(audioData, 'base64');
    messageState.audioBuffer = Buffer.concat([messageState.audioBuffer, newAudio]);

    if (messageState.audioBuffer.length > MAX_AUDIO_BYTES) {
        messageState.audioBuffer = messageState.audioBuffer.slice(-MAX_AUDIO_BYTES);
    }

    if (messageState.isRecordingAudio && !messageState.isTranscribing && messageState.audioBuffer.length >= 16000) {
        triggerTranscription(false, msgId);
    }
}

async function triggerTranscription(isFinalChunk = false, messageId = null) {
    const msgId = messageId || 'fallback';
    const messageState = getMessageState(msgId);

    if (messageState.isTranscribing) {
        console.log('⏳ Transcription already in progress, waiting for completion...');
        return new Promise((resolve) => {
            const checkInterval = setInterval(() => {
                if (!messageState.isTranscribing) {
                    clearInterval(checkInterval);
                    resolve();
                }
            }, 50);
        });
    }

    messageState.isTranscribing = true;

    try {
        const os = require('os');
        const tempWavFile = path.join(os.tmpdir(), `whisper-${Date.now()}-${process.pid}.wav`);
        const tempRawFile = path.join(os.tmpdir(), `audio-raw-${Date.now()}-${process.pid}.f32le`);
        const audioData = Buffer.from(messageState.audioBuffer);
        const audioDuration = messageState.audioBuffer.length / (16000 * 4);

        try {
            fs.writeFileSync(tempRawFile, audioData);

            execSync(`ffmpeg -y -f f32le -ar 16000 -ac 1 -i "${tempRawFile}" "${tempWavFile}" 2>/dev/null`, {
                stdio: 'ignore',
                shell: '/bin/bash',
                timeout: 10000
            });

            if (!fs.existsSync(tempWavFile)) {
                throw new Error('ffmpeg did not create output file');
            }
        } finally {
            try { fs.unlinkSync(tempRawFile); } catch {}
        }

        const result = await transcribeAudio(tempWavFile);
        const text = result.text;
        const segments = result.segments || [];

        try { fs.unlinkSync(tempWavFile); } catch {}

        if (text && activeSocket && (messageState.isRecordingAudio || isFinalChunk)) {
            const chunkLabel = isFinalChunk ? '[FINAL CHUNK]' : '[RAW]';
            console.log(`🎤 ${chunkLabel} Raw whisper: "${text}"`);

            const startTime = messageState.transcriptionCounter * 2;
            const endTime = startTime + 2;

            messageState.allTranscriptions.push({
                text: text,
                startTime: startTime,
                endTime: endTime,
                timestamp: Date.now()
            });

            messageState.transcriptionCounter++;

            const concatenatedText = deduplicateTranscription(text, messageState);

            if (!concatenatedText || concatenatedText.trim().length === 0) {
                console.log(`⏭️  Skipping (no unique words added)`);
                return;
            }

            if (activeSocket && (messageState.isRecordingAudio || isFinalChunk)) {
                const rawTranscription = {
                    type: 'transcription',
                    status: isFinalChunk ? 'final_chunk' : 'transcription',
                    transcription: concatenatedText,
                    timestamp: Date.now()
                };
                if (messageId) {
                    rawTranscription.messageId = messageId;
                }
                console.log(`📤 SENDING TO iOS: ${isFinalChunk ? 'FINAL_CHUNK' : 'TRANSCRIPTION'} "${concatenatedText}"${messageId ? ` (messageId: ${messageId})` : ''}`);
                activeSocket.write(JSON.stringify(rawTranscription) + '\n');
            }

            addToContext({ type: 'transcription', text: text, interim: !isFinalChunk });
        }
    } catch (err) {
        console.error(`❌ Interim transcription error: ${err.message}`);
    } finally {
        messageState.isTranscribing = false;
    }
}

async function handleAudioEnd(messageId = null) {
    console.log('🎤 Audio recording stopped (embedded flag)');

    const msgId = messageId || 'fallback';
    const messageState = getMessageState(msgId);

    messageState.isRecordingAudio = false;

    const concatenatedText = getConcatenatedText(messageState);
    console.log(`📝 Final concatenated text (${messageState.transcriptionHistory.length} entries): "${concatenatedText}"`);

    if (!concatenatedText || concatenatedText.trim().length === 0) {
        console.log('⚠️ No concatenated text, skipping final processing');
        cleanupMessageState(msgId);
        return;
    }

    try {
        if (activeSocket) {
            const rawTranscription = {
                type: 'transcription',
                status: 'transcription',
                transcription: concatenatedText,
                timestamp: Date.now()
            };
            if (messageId) {
                rawTranscription.messageId = messageId;
            }
            console.log(`📤 SENDING TO iOS: TRANSCRIPTION "${concatenatedText}"${messageId ? ` (messageId: ${messageId})` : ''}`);
            activeSocket.write(JSON.stringify(rawTranscription) + '\n');
        }

        addToContext({ type: 'transcription', text: concatenatedText, interim: false });

        console.log(`🤖 STAGE 1: Running Haiku correction on COMPLETE text (including final chunk)...`);
        console.log(`🤖 SENDING TO HAIKU: "${concatenatedText}"`);
        const { corrected } = await processWithHaiku(concatenatedText, 'correct_transcription', messageState.allTranscriptions);

        console.log(`✅ RECEIVED FROM HAIKU: "${corrected}"`);

        if (corrected !== concatenatedText) {
            addToContext({ type: 'corrected', raw: concatenatedText, corrected: corrected, interim: false });
        }

        console.log(`🎤 [FINAL] Raw: "${concatenatedText}"`);
        console.log(`🎤 [FINAL] Corrected: "${corrected}"`);

        if (activeSocket) {
            const promptMessage = {
                type: 'transcription',
                status: 'prompt',
                transcription: concatenatedText,
                prompt: corrected,
                summary: null,
                timestamp: Date.now()
            };
            if (messageId) {
                promptMessage.messageId = messageId;
            }
            console.log(`📤 SENDING TO iOS: PROMPT "${corrected}"${messageId ? ` (messageId: ${messageId})` : ''}`);
            activeSocket.write(JSON.stringify(promptMessage) + '\n');
        }

        console.log(`🤖 STAGE 2: Creating summary (in parallel with injection)...`);
        const summaryPromise = (async () => {
            let summary;
            try {
                const summaryResult = await processWithHaiku(corrected, 'create_summary');
                summary = summaryResult.summary;
                console.log(`✅ Summary created: "${summary}"`);
            } catch (err) {
                console.error(`❌ Summary creation failed: ${err.message}`);
                summary = corrected.substring(0, MAX_SUMMARY_CHARS);
            }

            if (activeSocket) {
                const summaryMessage = {
                    type: 'transcription',
                    status: 'summary',
                    transcription: concatenatedText,
                    prompt: corrected,
                    summary: summary,
                    timestamp: Date.now()
                };
                if (messageId) {
                    summaryMessage.messageId = messageId;
                }
                console.log(`📤 SENDING TO iOS: SUMMARY "${summary}"${messageId ? ` (messageId: ${messageId})` : ''}`);
                activeSocket.write(JSON.stringify(summaryMessage) + '\n');
            }
        })();

        console.log(`💉 Injecting corrected prompt into terminal: "${corrected}"`);
        injectIntoTerminal(corrected, async (success, error) => {
            if (success) {
                console.log('✅ Prompt injection successful');
            } else {
                console.error(`❌ Prompt injection failed: ${error}`);
            }

            await summaryPromise;
        });
    } catch (err) {
        console.error(`❌ Final transcription error: ${err.message}`);
    } finally {
        cleanupMessageState(msgId);
    }
}

function isAudioMessage(logData) {
    return logData.type === 'audio';
}

const server = net.createServer((socket) => {
    console.log('iOS client connected');
    activeSocket = socket;

    let buffer = '';

    socket.on('data', (data) => {
        try {
            buffer += data.toString();
            buffer = processBufferedData(socket, buffer);
        } catch (error) {
            console.error(`⚠️ Error processing data (continuing): ${error.message}`);
        }
    });

    socket.on('end', () => {
        console.log('iOS client disconnected - waiting for reconnection...');
        if (activeSocket === socket) {
            activeSocket = null;
        }
    });

    socket.on('error', (err) => {
        console.error(`⚠️ Socket error (continuing): ${err.message}`);
    });
});

loadLastAssistantMessage();

server.listen(8082, '0.0.0.0', () => {
    console.log(`Mac server listening on :8082 | ${getSessionCount()} sessions`);

    initializeClaudeMonitoring();
    initializeGitDiffWatcher();
});

function processBufferedData(socket, buffer) {
    let messagesProcessed = 0;
    let remainingBuffer = buffer;

    while (remainingBuffer.indexOf('\n') !== -1) {
        const newlineIndex = remainingBuffer.indexOf('\n');
        const line = remainingBuffer.substring(0, newlineIndex);
        remainingBuffer = remainingBuffer.substring(newlineIndex + 1);

        if (line.trim()) {
            try {
                const jsonData = JSON.parse(line);
                handleMessage(socket, jsonData);
                messagesProcessed++;
            } catch (error) {
                console.error('Failed to parse JSON:', error, 'Line:', line);
            }
        }
    }

    return remainingBuffer;
}

async function handleMessage(socket, logData) {
    if (isStartMessage(logData)) {
        handleStartMessage(socket);
    } else if (isPromptMessage(logData)) {
        handlePromptMessage(socket, logData);
    } else if (isSpeakMessage(logData)) {
        handleSpeakMessage(socket, logData);
    } else if (isAudioMessage(logData)) {
        await handleAudioMessage(socket, logData);
    } else if (isErrorMessage(logData)) {
        handleErrorMessage(socket, logData);
    } else if (isLogMessage(logData)) {
        handleLogMessage(socket, logData);
    } else {
        handleUnknownMessage(logData);
    }
}

function isSpeakMessage(logData) {
    return logData.type === 'speak';
}

const MAX_SPEAK_LENGTH = 50;

function handleSpeakMessage(socket, logData) {
    const { text, summary } = logData;

    if (!summary) {
        const response = { type: 'speak_result', success: false, error: 'No summary provided' };
        socket.write(JSON.stringify(response) + '\n');
        return;
    }

    if (summary.length > MAX_SPEAK_LENGTH) {
        const response = {
            type: 'speak_result',
            success: false,
            error: `Summary too long: ${summary.length} chars. Max is ${MAX_SPEAK_LENGTH}. Shorten it and try again.`
        };
        socket.write(JSON.stringify(response) + '\n');
        console.log(`❌ Speak rejected: ${summary.length} chars > ${MAX_SPEAK_LENGTH}`);
        return;
    }

    console.log(`🔊 Speaking: "${summary}" (full: "${(text || summary).substring(0, 50)}...")`);

    if (activeSocket) {
        const assistantMessage = {
            type: 'assistant_messages',
            messages: [{
                text: text || summary,
                summary: summary,
                timestamp: Date.now()
            }],
            timestamp: Date.now()
        };
        activeSocket.write(JSON.stringify(assistantMessage) + '\n');
    }

    const response = { type: 'speak_result', success: true };
    socket.write(JSON.stringify(response) + '\n');
}

function isStartMessage(logData) {
    return logData.type === 'start';
}

function isPromptMessage(logData) {
    return logData.type === 'prompt';
}

function isErrorMessage(logData) {
    return 'error' in logData.type;
}

function isLogMessage(logData) {
    return 'log' in logData.type;
}

function handleUnknownMessage(logData) {
    console.error('Unknown message type:', logData.type);
}

async function handleStartMessage(socket) {
    createNewSession();
    const stats = gatherSessionStatistics();
    await sendHandshakeResponse(socket, stats);
    logHandshakeDetails(stats);
}

function findLatestConversationFile(dir) {
    try {
        console.log(`🔎 Checking for conversation files in: ${dir}`);

        if (!fs.existsSync(dir)) {
            console.log(`📁 Directory doesn't exist: ${dir}`);
            return null;
        }

        const files = fs.readdirSync(dir)
            .filter(f => f.endsWith('.jsonl'))
            .map(f => ({
                name: f,
                path: path.join(dir, f),
                mtime: fs.statSync(path.join(dir, f)).mtime
            }))
            .sort((a, b) => b.mtime - a.mtime);

        if (files.length === 0) {
            console.log(`❌ No conversation files found in: ${dir}`);
            return null;
        }

        const latestFile = files[0];
        const modTime = new Date(latestFile.mtime).toLocaleString();
        console.log(`✅ Found latest conversation: ${latestFile.name} (modified: ${modTime})`);
        return latestFile.path;
    } catch (e) {
        console.error(`❌ Error finding conversation file in ${dir}:`, e.message);
        return null;
    }
}


function handlePromptMessage(socket, logData) {
    const { prompt, timestamp } = logData;
    console.log(`📨 Received prompt from iOS app:`);
    console.log(`   Prompt: "${prompt}"`);
    console.log(`   Timestamp: ${new Date(timestamp * 1000).toLocaleString()}`);

    promptCounter++;
    const promptId = `${promptCounter}:`;
    console.log(`🔖 Assigned ID: ${promptId}`);

    if (prompt === '[Request interrupted by user]') {
        console.log('🛑 Detected stop signal - sending ESC instead of typing text');

        switchToWindow(CLAUDE_WINDOW_PATTERN, (switchSuccess, switchError) => {
            if (!switchSuccess) {
                console.log(`⚠️ Failed to switch to Claude Code window: ${switchError}`);
                console.log(`📝 Proceeding with interrupt anyway...`);
            }

            const appleScript = `tell application "Terminal"
    activate
end tell

delay 0.2

tell application "System Events"
    key code 53
end tell`;

            const os = require('os');
            const scriptFile = path.join(os.tmpdir(), `applescript-${Date.now()}-${process.pid}.scpt`);
            const outputFile = path.join(os.tmpdir(), `applescript-out-${Date.now()}-${process.pid}.txt`);

            try {
                fs.writeFileSync(scriptFile, appleScript);
                execSync(`osascript "${scriptFile}" > "${outputFile}" 2>&1`, {
                    stdio: 'ignore',
                    shell: '/bin/bash',
                    timeout: 10000
                });

                console.log('✅ ESC key sent to Terminal');

                const ackMessage = {
                    type: 'prompt_ack',
                    status: 'success',
                    method: 'interrupt_esc_sent',
                    originalPrompt: prompt,
                    timestamp: Date.now()
                };

                socket.write(JSON.stringify(ackMessage) + '\n');
                console.log('✅ Interrupt acknowledged to iOS!');
            } catch (error) {
                console.log(`❌ Failed to send ESC: ${error.message}`);

                const ackMessage = {
                    type: 'prompt_ack',
                    status: 'error',
                    error: `Failed to send ESC: ${error.message}`,
                    originalPrompt: prompt,
                    timestamp: Date.now()
                };

                socket.write(JSON.stringify(ackMessage) + '\n');
            } finally {
                try { fs.unlinkSync(scriptFile); } catch {}
                try { fs.unlinkSync(outputFile); } catch {}
            }
        });

        return;
    }

    pendingPrompts.set(promptId, {
        originalPrompt: prompt,
        timestamp: Date.now(),
        verified: false
    });
    console.log(`📝 Added prompt to tracking (${pendingPrompts.size} total)`);

    const promptWithId = `${promptId} ${prompt}`;
    console.log(`💉 Injecting with ID: "${promptWithId}"`);

    injectIntoTerminal(promptWithId, (terminalSuccess, terminalError) => {
        if (terminalSuccess) {
            console.log('✅ Terminal automation executed successfully!');
        } else {
            console.log(`❌ Terminal automation failed: ${terminalError}`);

            const ackMessage = {
                type: 'prompt_ack',
                status: 'error',
                error: `Terminal automation failed: ${terminalError}`,
                originalPrompt: prompt,
                timestamp: Date.now()
            };

            const jsonData = JSON.stringify(ackMessage) + '\n';
            socket.write(jsonData);
            console.log('📤 Sent Terminal failure acknowledgment');

            pendingPrompts.delete(promptId);
        }
    });
}

function createNewSession() {
    try {
        currentSessionNumber = getSessionCount() + 1;
        currentSessionFile = path.join(logsDir, `${currentSessionNumber}.json`);
        fs.writeFileSync(currentSessionFile, '');
    } catch (error) {
        console.error(`⚠️ Failed to create session file (continuing): ${error.message}`);
    }
}

function gatherSessionStatistics() {
    const uptimeStats = computeUptimeStats();
    const totalLogs = countAllLogs();

    return {
        sessionNumber: currentSessionNumber,
        totalUptime: uptimeStats.totalUptime,
        todayUptime: uptimeStats.todayUptime,
        totalLogs: totalLogs
    };
}

function computeUptimeStats() {
    const files = getAllSessionFiles();

    if (noSessionsExist(files)) {
        return { totalUptime: 0, todayUptime: 0 };
    }

    const today = getMidnightToday();
    let totalUptime = 0;
    let todayUptime = 0;

    files.forEach(file => {
        const sessionUptime = calculateSessionUptime(file);
        totalUptime += sessionUptime.duration;

        if (isSessionFromToday(sessionUptime.startTime, today)) {
            todayUptime += sessionUptime.duration;
        }
    });

    return {
        totalUptime: Math.floor(totalUptime),
        todayUptime: Math.floor(todayUptime)
    };
}

function noSessionsExist(files) {
    return files.length === 0;
}

function getMidnightToday() {
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    return today;
}

function calculateSessionUptime(file) {
    const filePath = path.join(logsDir, file);
    const content = fs.readFileSync(filePath, 'utf8');
    const lines = content.split('\n').filter(line => line.trim());

    if (sessionHasNoLogs(lines)) {
        return { duration: 0, startTime: new Date() };
    }

    const firstLog = JSON.parse(lines[0]);
    const lastLog = JSON.parse(lines[lines.length - 1]);

    const startTime = new Date(firstLog.timestamp);
    const endTime = new Date(lastLog.timestamp);
    const duration = endTime - startTime;

    return { duration, startTime };
}

function sessionHasNoLogs(lines) {
    return lines.length === 0;
}

function isSessionFromToday(sessionStartTime, today) {
    return sessionStartTime >= today;
}

function countAllLogs() {
    let totalLogs = 0;

    getAllSessionFiles().forEach(file => {
        const content = fs.readFileSync(path.join(logsDir, file), 'utf8');
        totalLogs += countLinesInContent(content);
    });

    return totalLogs;
}

function getAllSessionFiles() {
    return fs.readdirSync(logsDir).filter(f => f.endsWith('.json'));
}

function countLinesInContent(content) {
    return content.split('\n').filter(line => line.trim()).length;
}

async function sendHandshakeResponse(socket, stats) {
    const apiKey = fs.readFileSync(path.join('private', 'secrets.txt'), 'utf8').trim();

    const previousErrors = getPreviousSessionErrors(stats.sessionNumber);

    // Summarize the last assistant message if we have one
    let assistantMessageSummary = null;
    if (lastSentAssistantMessage) {
        console.log(`📝 Summarizing last assistant message for handshake...`);
        try {
            assistantMessageSummary = await summarizeWithClaude(lastSentAssistantMessage);
        } catch (error) {
            console.error(`⚠️ Failed to summarize assistant message: ${error.message}`);
        }
    }

    const handshakeResponse = JSON.stringify({
        type: 'handshake',
        sessionNumber: stats.sessionNumber,
        totalUptime: stats.totalUptime,
        todayUptime: stats.todayUptime,
        totalLogs: stats.totalLogs,
        apiKey: apiKey,
        previousErrors: previousErrors,
        currentAssistantMessage: lastSentAssistantMessage,
        currentAssistantMessageSummary: assistantMessageSummary
    }) + '\n';

    socket.write(handshakeResponse);

    sendGitDiffToiOS(true);

    if (previousErrors.length > 0) {
        console.log(`📤 Sent ${previousErrors.length} previous error(s) to iOS app`);
    }

    if (lastSentAssistantMessage) {
        console.log(`📤 Handshake includes assistant message: ${lastSentAssistantMessage.substring(0, 100)}...`);
        if (assistantMessageSummary) {
            console.log(`📤 Summary: "${assistantMessageSummary}"`);
        }
    } else {
        console.log(`📤 Handshake sent with no assistant message (null)`);
    }
}

function getPreviousSessionErrors(currentSessionNumber) {
    const previousSessionNumber = currentSessionNumber - 1;
    const previousSessionFile = path.join(logsDir, `${previousSessionNumber}.json`);

    if (!fs.existsSync(previousSessionFile)) {
        return [];
    }

    try {
        const fileContent = fs.readFileSync(previousSessionFile, 'utf8');
        const lines = fileContent.trim().split('\n');

        const errors = lines
            .map(line => {
                try {
                    return JSON.parse(line);
                } catch {
                    return null;
                }
            })
            .filter(log => log && log.type && log.type.error !== undefined)
            .map(log => ({
                message: log.message,
                fileName: log.fileName,
                functionName: log.functionName,
                timestamp: log.timestamp
            }));

        return errors;
    } catch (error) {
        console.error(`Failed to read previous session errors: ${error.message}`);
        return [];
    }
}

function logHandshakeDetails(stats) {
    console.log('Sent handshake with session number:', stats.sessionNumber);
    console.log('Included stats - Total:', stats.totalUptime + 'ms, Today:', stats.todayUptime + 'ms, Logs:', stats.totalLogs);
}

function handleLogMessage(socket, logData) {
    console.log('Received log:', logData.message);
    persistLogToFile(logData);
    confirmLogReception(socket, logData.id);
}

function handleErrorMessage(socket, logData) {
    reportErrorToConsole(logData);
    persistLogToFile(logData);
    confirmLogReception(socket, logData.id);

    // Only restart for manual restart trigger (after confirmation)
    if (logData.message === "Manual restart triggered from log view") {
        executeDeployment();
    }
}

function reportErrorToConsole(logData) {
    console.error(`🚨 ERROR: ${logData.message} [${logData.fileName}:${logData.functionName}] - test will fail`);
}

function persistLogToFile(logData) {
    writeLogToFile(logData);
}

function confirmLogReception(socket, logId) {
    sendAcknowledgment(socket, logId);
}

function getSessionCount() {
    const files = fs.readdirSync(logsDir);
    return files.filter(f => f.endsWith('.json')).length;
}

function writeLogToFile(logData) {
    if (!currentSessionFile) {
        console.error('⚠️ No active session file!');
        return;
    }
    try {
        fs.appendFileSync(currentSessionFile, JSON.stringify(logData) + '\n');
    } catch (error) {
        console.error(`⚠️ Failed to write log (continuing): ${error.message}`);
    }
}

function sendAcknowledgment(socket, logId) {
    try {
        const ackMessage = JSON.stringify({
            type: 'ack',
            logId: logId
        }) + '\n';

        socket.write(ackMessage);
    } catch (error) {
        console.error(`⚠️ Failed to send acknowledgment (continuing): ${error.message}`);
    }
}

let pendingPrompts = new Map();
let promptCounter = 0;

function loadLastAssistantMessage() {
    try {
        if (fs.existsSync(lastAssistantMessageFile)) {
            lastSentAssistantMessage = fs.readFileSync(lastAssistantMessageFile, 'utf8');
            console.log(`📋 Loaded last assistant message from disk: ${lastSentAssistantMessage.substring(0, 80)}...`);
        } else {
            console.log('📋 No previous assistant message found');
        }
    } catch (error) {
        console.error(`⚠️ Failed to load last assistant message: ${error.message}`);
    }
}

function saveLastAssistantMessage(message) {
    try {
        fs.writeFileSync(lastAssistantMessageFile, message, 'utf8');
    } catch (error) {
        console.error(`⚠️ Failed to save last assistant message: ${error.message}`);
    }
}

function initializeClaudeMonitoring() {
    const claudeProjectsPath = path.join(process.env.HOME, '.claude', 'projects');

    const watcher = chokidar.watch(claudeProjectsPath, {
        persistent: true,
        ignoreInitial: false,
        recursive: true,
        depth: 99,
        awaitWriteFinish: {
            stabilityThreshold: 500,
            pollInterval: 100
        }
    });

    watcher.on('change', (filePath) => {
        if (filePath.endsWith('.jsonl')) {
            checkForInjectedPrompts(filePath);
        } else {
            console.log(`⏭️  Skipping non-jsonl file`);
        }
    });

    watcher.on('error', (error) => {
        console.error('❌ Watcher error:', error);
    });

    watcher.on('ready', () => {
        console.log(`✅ Prompt monitoring active on ${claudeProjectsPath}`);
    });
}

function initializeGitDiffWatcher() {
    const repoPath = path.join(__dirname, '..');

    const watcher = chokidar.watch(repoPath, {
        persistent: true,
        ignoreInitial: true,
        ignored: [
            '**/node_modules/**',
            '**/.git/**',
            '**/build/**',
            '**/Build/**',
            '**/DerivedData/**',
            '**/*.log',
            '**/private/**'
        ],
        awaitWriteFinish: {
            stabilityThreshold: 200,
            pollInterval: 100
        }
    });

    watcher.on('all', (event, filePath) => {
        if (diffDebounceTimer) {
            clearTimeout(diffDebounceTimer);
        }

        diffDebounceTimer = setTimeout(() => {
            sendGitDiffToiOS();
        }, 500);
    });

    watcher.on('error', (error) => {
        console.error('❌ Git diff watcher error:', error);
    });

    watcher.on('ready', () => {
        console.log(`✅ Git diff monitoring active on ${repoPath}`);
        sendGitDiffToiOS();
    });
}

function sendGitDiffToiOS(force = false) {
    const os = require('os');
    const scriptPath = path.join(__dirname, 'get-diff.sh');
    const outputFile = path.join(os.tmpdir(), `git-diff-${Date.now()}-${process.pid}.txt`);

    try {
        execSync(`"${scriptPath}" > "${outputFile}" 2>&1`, {
            stdio: 'ignore',
            shell: '/bin/bash',
            timeout: 5000
        });

        const diff = fs.readFileSync(outputFile, 'utf8').trim();

        if (!force && diff === lastDiffSent) {
            return;
        }

        lastDiffSent = diff;

        if (activeSocket) {
            const diffMessage = {
                type: 'code_diff',
                diff: diff,
                timestamp: Date.now()
            };

            const jsonData = JSON.stringify(diffMessage) + '\n';
            activeSocket.write(jsonData);

            const diffSummary = diff.length > 0 ? `${diff.split('\n').length} lines` : 'empty';
            console.log(`📤 Sent git diff to iOS: ${diffSummary}${force ? ' (forced during handshake)' : ''}`);
        }
    } catch (error) {
        console.log(`⚠️ Failed to get git diff: ${error.message}`);
    } finally {
        try { fs.unlinkSync(outputFile); } catch {}
    }
}

function checkForInjectedPrompts(filePath) {
    try {
        const fileContent = fs.readFileSync(filePath, 'utf8');
        const lines = fileContent.trim().split('\n');

        const allUserEvents = [];
        const allAssistantEvents = [];
        for (const line of lines) {
            try {
                const event = JSON.parse(line);

                if (event.type === 'user' &&
                    event.message &&
                    event.message.role === 'user' &&
                    event.message.content) {

                    if (typeof event.message.content === 'string') {
                        allUserEvents.push({
                            text: event.message.content,
                            timestamp: event.timestamp
                        });
                    }
                    else if (Array.isArray(event.message.content)) {
                        for (const content of event.message.content) {
                            if (content.type === 'text' &&
                                content.text &&
                                typeof content.text === 'string') {
                                allUserEvents.push({
                                    text: content.text,
                                    timestamp: event.timestamp
                                });
                            }
                        }
                    }
                }

                if (event.type === 'assistant' &&
                    event.message &&
                    event.message.role === 'assistant' &&
                    event.message.content) {

                    if (typeof event.message.content === 'string') {
                        allAssistantEvents.push({
                            text: event.message.content,
                            timestamp: event.timestamp
                        });
                    }
                    else if (Array.isArray(event.message.content)) {
                        for (const content of event.message.content) {
                            if (content.type === 'text' &&
                                content.text &&
                                typeof content.text === 'string') {
                                allAssistantEvents.push({
                                    text: content.text,
                                    timestamp: event.timestamp
                                });
                            }
                        }
                    }
                }
            } catch (parseErr) {
                continue;
            }
        }

        const userEvents = allUserEvents.slice(-5);

        const lastMessage = userEvents.length > 0 ? userEvents[userEvents.length - 1].text.substring(0, 100).replace(/\n/g, ' ') : 'none';


        for (const [promptId, data] of pendingPrompts.entries()) {
            if (!data.verified) {
                console.log(`🔍 Checking pending prompt ID: ${promptId}`);
                console.log(`   Original prompt: "${data.originalPrompt.substring(0, 60)}..."`);

                let matchedIndex = -1;
                let matchedEvent = null;

                for (let i = 0; i < userEvents.length; i++) {
                    if (userEvents[i].text.includes(promptId)) {
                        matchedIndex = i;
                        matchedEvent = userEvents[i];
                        break;
                    }
                }

                if (matchedEvent) {
                    console.log(`✅ MATCH FOUND in message [${matchedIndex + 1}] of last 5 user messages!`);
                    console.log(`   Found ID: ${promptId}`);
                    console.log(`   Message preview: "${matchedEvent.text.substring(0, 80).replace(/\n/g, ' ')}..."`);
                    console.log('📍 Found in conversation events:', path.basename(filePath));

                    data.verified = true;
                    data.verifiedAt = Date.now();

                    if (activeSocket) {
                        // Summarize the user's prompt and send with ack
                        sendPromptAckWithSummary(data.originalPrompt);
                    }

                    pendingPrompts.delete(promptId);
                } else {
                    console.log(`❌ ID ${promptId} NOT FOUND in last 5 user messages`);
                    console.log(`   Prompt may not have appeared in conversation yet`);
                }
            }
        }

        const verifiedCount = Array.from(pendingPrompts.values()).filter(p => p.verified).length;
        const pendingCount = pendingPrompts.size - verifiedCount;

        if (pendingCount > 0) {
            console.log(`⏳ Pending prompts:`);
            let index = 1;
            for (const [promptId, data] of pendingPrompts.entries()) {
                if (!data.verified) {
                    console.log(`   [${index}] ID: ${promptId}`);
                    console.log(`       Prompt: "${data.originalPrompt.substring(0, 100)}..."`);
                    console.log(`       Age: ${Math.round((Date.now() - data.timestamp) / 1000)}s`);
                    index++;
                }
            }
        }

        // Check for new assistant messages to send to iOS
        if (allAssistantEvents.length > 0) {
            const latestAssistant = allAssistantEvents[allAssistantEvents.length - 1];

            // Only send if this is a genuinely new message (different content)
            if (latestAssistant.text !== lastSentAssistantMessage) {
                console.log(`📨 New assistant message detected: "${latestAssistant.text.substring(0, 80)}..."`);

                // Save IMMEDIATELY to prevent duplicate sends (before async summarization)
                lastSentAssistantMessage = latestAssistant.text;
                saveLastAssistantMessage(latestAssistant.text);

                // Summarize and send to iOS
                sendAssistantMessageToiOS(latestAssistant.text);
            }
        }

    } catch (err) {
        console.error(`❌ Error checking file ${filePath}:`, err.message);
    }
}

async function sendPromptAckWithSummary(originalPrompt) {
    try {
        const summary = await summarizeWithClaude(originalPrompt);

        addToContext({ type: 'user_message', text: originalPrompt, summary: summary });

        const ackMessage = {
            type: 'prompt_ack',
            status: 'success',
            method: 'conversation_event_verification',
            originalPrompt: originalPrompt,
            summary: summary,
            timestamp: Date.now()
        };

        activeSocket.write(JSON.stringify(ackMessage) + '\n');
        console.log(`✅ Prompt verified with summary: "${summary}"`);
    } catch (error) {
        console.error(`❌ Failed to summarize prompt: ${error.message}`);
        addToContext({ type: 'user_message', text: originalPrompt, summary: null });

        const ackMessage = {
            type: 'prompt_ack',
            status: 'success',
            method: 'conversation_event_verification',
            originalPrompt: originalPrompt,
            timestamp: Date.now()
        };
        activeSocket.write(JSON.stringify(ackMessage) + '\n');
        console.log('✅ Prompt verified (no summary)');
    }
}

async function sendAssistantMessageToiOS(text) {
    if (!activeSocket) {
        console.log('   ⚠️ No iOS client connected - skipping');
        return;
    }

    try {
        const cachedEntry = assistantSummaryCache.find(entry => entry.text === text);

        if (cachedEntry) {
            console.log(`⏭️  Message already in cache - already processed and sent, skipping`);
            return;
        }

        const summary = await summarizeWithClaude(text);
        console.log(`✅ Created new summary: "${summary}"`);

        assistantSummaryCache.push({ text: text, summary: summary });
        if (assistantSummaryCache.length > MAX_SUMMARY_CACHE_SIZE) {
            assistantSummaryCache.shift();
        }

        addToContext({ type: 'assistant_message', text: text, summary: summary });

        const assistantMessage = {
            type: 'assistant_messages',
            messages: [{
                text: text,
                summary: summary,
                timestamp: Date.now()
            }],
            timestamp: Date.now()
        };

        activeSocket.write(JSON.stringify(assistantMessage) + '\n');
        console.log(`✅ Sent assistant message to iOS with summary: "${summary}"`);
    } catch (error) {
        console.error(`❌ Failed to send assistant message: ${error.message}`);
    }
}

function executeDeployment() {
    const os = require('os');
    const outputFile = path.join(os.tmpdir(), `pgrep-out-${Date.now()}-${process.pid}.txt`);

    try {
        execSync('pgrep -f "deploy-in-window.sh" > "' + outputFile + '" 2>&1', {
            stdio: 'ignore',
            shell: '/bin/bash',
            timeout: 5000
        });

        const result = fs.readFileSync(outputFile, 'utf8').trim();
        if (result) {
            console.log('⚠️ Deployment already in progress, skipping duplicate restart');
            return;
        }
    } catch (error) {
    } finally {
        try { fs.unlinkSync(outputFile); } catch {}
    }

    console.log('🚀 Executing deployment in scripts window...');

    const scriptOutputFile = path.join(os.tmpdir(), `deploy-out-${Date.now()}-${process.pid}.txt`);

    try {
        execSync('./scripts/deploy-in-window.sh > "' + scriptOutputFile + '" 2>&1 &', {
            stdio: 'ignore',
            shell: '/bin/bash',
            timeout: 1000
        });

        console.log('✅ Deployment process spawned and detached');
    } catch (error) {
        console.error(`❌ Failed to spawn deployment: ${error.message}`);
    } finally {
        try { fs.unlinkSync(scriptOutputFile); } catch {}
    }
}

function switchToWindow(windowNamePattern, callback) {
    console.log(`🪟 Switching to Terminal window containing: "${windowNamePattern}"`);

    const appleScript = `tell application "Terminal"
    activate
    repeat with w from 1 to count of windows
        if name of window w contains "${windowNamePattern}" then
            set index of window w to 1
            return "success: Switched to window " & w
        end if
    end repeat
    return "error: No window found containing '${windowNamePattern}'"
end tell`;

    const os = require('os');
    const scriptFile = path.join(os.tmpdir(), `applescript-${Date.now()}-${process.pid}.scpt`);
    const outputFile = path.join(os.tmpdir(), `applescript-out-${Date.now()}-${process.pid}.txt`);

    try {
        fs.writeFileSync(scriptFile, appleScript);
        execSync(`osascript "${scriptFile}" > "${outputFile}" 2>&1`, {
            stdio: 'ignore',
            shell: '/bin/bash',
            timeout: 10000
        });

        const result = fs.readFileSync(outputFile, 'utf8').trim();

        if (result.includes('error:')) {
            console.log(`   ❌ ${result}`);
            callback(false, result);
        } else {
            console.log(`   ✅ ${result}`);
            callback(true);
        }
    } catch (error) {
        console.log(`   ❌ Failed to switch window: ${error.message}`);
        callback(false, error.message);
    } finally {
        try { fs.unlinkSync(scriptFile); } catch {}
        try { fs.unlinkSync(outputFile); } catch {}
    }
}

function injectIntoTerminal(prompt, callback) {
    const escapedPrompt = prompt
        .replace(/"/g, '')
        .replace(/'/g, '');

    console.log(`🔤 Injecting prompt into Terminal: "${escapedPrompt}"`);

    switchToWindow(CLAUDE_WINDOW_PATTERN, (switchSuccess, switchError) => {
        if (!switchSuccess) {
            console.log(`⚠️ Failed to switch to Claude Code window: ${switchError}`);
            console.log(`📝 Proceeding with injection anyway...`);
        }

        const appleScript = `tell application "Terminal"
    activate
end tell

delay 0.2

tell application "System Events"
    tell process "Terminal"
        set frontmost to true

        try
            perform action "AXRaise" of window 1
        end try

        keystroke "${escapedPrompt}"

        delay 1

        key code 36

        return "success: Typed into Terminal (macOS 26 enhanced method)"
    end tell
end tell`;

        console.log('🍎 Executing enhanced AppleScript for macOS 26 Tahoe...');

        const os = require('os');
        const scriptFile = path.join(os.tmpdir(), `applescript-${Date.now()}-${process.pid}.scpt`);
        const outputFile = path.join(os.tmpdir(), `applescript-out-${Date.now()}-${process.pid}.txt`);

        try {
            fs.writeFileSync(scriptFile, appleScript);
            execSync(`osascript "${scriptFile}" > "${outputFile}" 2>&1`, {
                stdio: 'ignore',
                shell: '/bin/bash',
                timeout: 10000
            });

            const result = fs.readFileSync(outputFile, 'utf8').trim();

            console.log('📝 AppleScript result:');
            if (result.includes('error:')) {
                console.log(`   Output: ${result}`);
                callback(false, result);
            } else {
                console.log(`   Success: ${result}`);
                callback(true);
            }
        } catch (error) {
            console.log(`   Error: ${error.message}`);
            console.log(`   Note: Ensure Terminal has Accessibility permissions in System Settings`);
            callback(false, `AppleScript error: ${error.message}`);
        } finally {
            try { fs.unlinkSync(scriptFile); } catch {}
            try { fs.unlinkSync(outputFile); } catch {}
        }
    });
}

