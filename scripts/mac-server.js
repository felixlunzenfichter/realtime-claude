/*
 * MAC-SERVER.JS
 *
 * MESSAGE TYPES (JSON over TCP socket):
 * - {type:'start'} → iOS app starting/reconnecting
 * - {type:'audio', audioData:base64, isStart:bool, isEnd:bool, messageId:str} → voice input
 * - {type:'delete', messageId:str} → user deleted message
 * - {type:'prompt', prompt:str, timestamp:num, messageId:str} → typed/manual prompt
 * - {type:'speak', text:str, summary:str} → assistant response to be spoken
 * - {type:'log', message:str, fileName:str, functionName:str} → info log
 * - {type:'error', message:str, fileName:str, functionName:str} → error log
 *
 * RESPONSES TO iOS:
 * - {type:'handshake', sessionNumber, totalUptime, todayUptime, totalLogs, apiKey, previousErrors, currentAssistantMessage, currentAssistantMessageSummary, messageId}
 * - {type:'transcription', messageId, timestamp, transcription} → interim whisper output
 * - {type:'prompt', messageId, timestamp, prompt} → corrected/final prompt
 * - {type:'summary', messageId, timestamp, summary} → user/assistant message summary
 * - {type:'assistant', messageId, timestamp, prompt, summary} → assistant message from conversation
 * - {type:'speak_result', success:bool, error?:str} → speak validation result
 * - {type:'prompt_ack', messageId, timestamp, status, summary, error?} → prompt received/verified
 * - {type:'claude_state', state:str, isActive:bool, timestamp} → claude active/idle
 * - {type:'code_diff', diff:str, timestamp} → git diff output
 * - {type:'ack', logId} → log received confirmation
 *
 * const net, fs, path, {execSync}, chokidar, FormData, fetch, {Worker}
 * process.on('uncaughtException'), process.on('unhandledRejection')
 *
 * logsDir = 'private/logs'
 * lastAssistantMessageFile = 'private/last-assistant-message.txt'
 * CLAUDE_WINDOW_PATTERN = 'claude --dangerously-skip-permissions'
 * WHISPER_SERVER_URL = 'http://localhost:5050'
 * currentSessionFile, currentSessionNumber
 * activeSocket
 *
 * lastDiffSent, diffDebounceTimer
 *
 * claudeIsActive, lastActivitySentTime
 *
 * MAX_AUDIO_DURATION=10, MAX_AUDIO_BYTES
 *
 * MAX_SUMMARY_CHARS=50, MAX_CONTEXT_EVENTS=20, MAX_SPEAK_LENGTH=25
 *
 * assistantSummaryCache[], MAX_SUMMARY_CACHE_SIZE=5
 *
 * haikuContext[]
 *
 * messageStates=Map{messageId→{audioBuffer,isTranscribing,isRecordingAudio,shortTranscription,completeTranscription,deleted,injected,audioEnded}}
 *
 * haikuPriorityQueue.add(priority, task, description) → queue.push, queue.sort, processNext
 * haikuPriorityQueue.processNext() → queue.shift, task(), processNext | isProcessing=true/false
 *
 * getMessageState(messageId) → messageStates.get/set
 * addToContext(event) → haikuContext.push | shift if >MAX_CONTEXT_EVENTS
 * formatContextForHaiku() → map haikuContext to strings
 *
 * buildPrompt(text, task, completeTranscription?) → formatContextForHaiku, prompt string
 * processWithHaiku(text, task, completeTranscription?) → Worker(haiku-worker.js), parse JSON | {corrected}|{summary}
 *
 * deduplicateTranscription(newText, messageState, timestamp) → word-level dedup | messageState.shortTranscription+=unique, completeTranscription+=timestamped
 * transcribeAudio(audioPath) → fetch(WHISPER_SERVER_URL/transcribe) | {text, segments}
 * handleAudioMessage(socket, {audioData, isStart, isEnd, messageId}) → getMessageState, audioBuffer management, triggerTranscription | messageState.audioEnded=true on isEnd
 * triggerTranscription(messageId) → ffmpeg, transcribeAudio, deduplicateTranscription, activeSocket.write(transcription) | messageState.isTranscribing=true/false, handleAudioEnd if audioEnded
 * handleAudioEnd(messageId) → activeSocket.write(final transcription), haikuPriorityQueue.add(correction priority=1), haikuPriorityQueue.add(summary priority=2), injectIntoTerminal | messageState.isRecordingAudio=false
 *
 * isAudioMessage, isDeleteMessage, isStartMessage, isPromptMessage, isSpeakMessage, isErrorMessage, isLogMessage
 * handleDeleteMessage({messageId}) → messageState.deleted=true
 *
 * server=net.createServer → activeSocket=socket, readClaudeState, processBufferedData
 * loadLastAssistantMessage()
 * server.listen(8082) → initializeClaudeMonitoring, initializeGitDiffWatcher
 * processBufferedData(socket, buffer) → JSON.parse lines, handleMessage
 * handleMessage(socket, logData) → route to handlers
 *
 * isSpeakMessage
 * handleSpeakMessage(socket, {text, summary}) → validate length, activeSocket.write(assistant message)
 * isStartMessage, isPromptMessage, isErrorMessage, isLogMessage
 * handleUnknownMessage(logData)
 * handleStartMessage(socket) → createNewSession, gatherSessionStatistics, sendHandshakeResponse, logHandshakeDetails
 * findLatestConversationFile(dir) → .jsonl files sorted by mtime
 * handlePromptMessage(socket, {prompt, timestamp, messageId}) → detect interrupt, pendingPrompts.set, injectIntoTerminal | promptCounter++
 *
 * createNewSession() → currentSessionNumber++, fs.writeFileSync(currentSessionFile)
 * gatherSessionStatistics() → {sessionNumber, totalUptime, todayUptime, totalLogs}
 * computeUptimeStats() → getAllSessionFiles, calculateSessionUptime, isSessionFromToday | {totalUptime, todayUptime}
 * noSessionsExist(files)
 * getMidnightToday()
 * calculateSessionUptime(file) → {duration, startTime}
 * sessionHasNoLogs(lines)
 * isSessionFromToday(sessionStartTime, today)
 * countAllLogs() → getAllSessionFiles, countLinesInContent
 * getAllSessionFiles() → .json files
 * countLinesInContent(content)
 * sendHandshakeResponse(socket, stats) → getPreviousSessionErrors, activeSocket.write(handshake), sendGitDiffToiOS, haikuPriorityQueue.add(handshake_summary priority=3)
 * getPreviousSessionErrors(currentSessionNumber) → read previous session .json, filter error logs
 * logHandshakeDetails(stats)
 *
 * handleLogMessage(socket, logData) → persistLogToFile, sendAcknowledgment
 * handleErrorMessage(socket, logData) → reportErrorToConsole, persistLogToFile, sendAcknowledgment, executeDeployment if manual restart
 * reportErrorToConsole(logData)
 * persistLogToFile(logData) → writeLogToFile
 * getSessionCount()
 * writeLogToFile(logData) → fs.appendFileSync(currentSessionFile)
 * sendAcknowledgment(socket, logId) → socket.write({type:'ack'}) (silent, no logging)
 *
 * pendingPrompts=Map, promptCounter
 * loadLastAssistantMessage() → fs.readFileSync(lastAssistantMessageFile) | lastSentAssistantMessage=text
 * saveLastAssistantMessage(message) → fs.writeFileSync
 *
 * initializeClaudeMonitoring() → chokidar.watch(claude-state.txt), chokidar.watch(claudeProjectsPath) | stateWatcher.on(add/change→readClaudeState), conversationWatcher.on(change→checkForInjectedPrompts)
 * initializeGitDiffWatcher() → chokidar.watch(repoPath), watcher.on(all→sendGitDiffToiOS debounced 500ms)
 * readClaudeState(filePath) → parse state|timestamp, activeSocket.write({type:'claude_state', state:'idle'}) if stopped/finished | claudeIsActive=false
 * sendGitDiffToiOS(force?) → execSync(get-diff.sh), activeSocket.write({type:'code_diff'}) | lastDiffSent=diff
 * checkForInjectedPrompts(filePath) → parse .jsonl, find user/assistant events, detect interrupts, verify pendingPrompts, sendPromptAckWithSummary, sendAssistantMessageToiOS | activeSocket.write(claude_state), lastSentAssistantMessage=text
 * sendPromptAckWithSummary(originalPrompt, messageId) → extract embedded summary or haikuPriorityQueue.add(summary priority=2), activeSocket.write({type:'summary'}), addToContext
 * sendAssistantMessageToiOS(text) → assistantSummaryCache check, activeSocket.write({type:'assistant'}) | assistantSummaryCache.push/shift
 *
 * executeDeployment() → execSync(pgrep), execSync(deploy-in-window.sh) if not running
 * switchToWindow(windowNamePattern, callback) → osascript tell Terminal, callback(success/error)
 * injectIntoTerminal(prompt, callback) → switchToWindow, osascript keystroke+enter
 */

const net = require('net');
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const chokidar = require('chokidar');
const FormData = require('form-data');
const fetch = require('node-fetch');
const { Worker } = require('worker_threads');
const crypto = require('crypto');

const IS_TEST = process.env.IS_TEST === 'true';
const MANUAL_TESTING = process.env.MANUAL_TESTING === 'true';
const SERVER_PORT = parseInt(process.env.SERVER_PORT, 10) || 8082;

// ============================================
// UNIFIED LOGGING (writes to same file as iOS)
// ============================================

function log(message, functionName = 'unknown') {
    console.log(message);
    if (currentSessionFile) {
        writeLogToFile({
            type: { log: {} },
            message: message,
            fileName: 'mac-server.js',
            functionName: functionName,
            timestamp: new Date().toISOString(),
            id: crypto.randomUUID()
        });
    }
}

function error(message, functionName = 'unknown') {
    console.error(`🚨 ERROR: ${message} - test will fail`);
    if (currentSessionFile) {
        writeLogToFile({
            type: { error: {} },
            message: message,
            fileName: 'mac-server.js',
            functionName: functionName,
            timestamp: new Date().toISOString(),
            id: crypto.randomUUID()
        });
    }
}

function debugLog(message) {
    console.log(message);
}

process.on('uncaughtException', (err) => {
    error(`Uncaught exception (continuing): ${err.stack || err}`, 'uncaughtException');
});

process.on('unhandledRejection', (reason, promise) => {
    error(`Unhandled promise rejection (continuing): ${reason}`, 'unhandledRejection');
});

function closeAllWatchers() {
    if (stateWatcher) {
        stateWatcher.close();
        stateWatcher = null;
    }
    if (conversationWatcher) {
        conversationWatcher.close();
        conversationWatcher = null;
    }
    if (gitDiffWatcher) {
        gitDiffWatcher.close();
        gitDiffWatcher = null;
    }
    if (typeof configWatcher !== 'undefined' && configWatcher) {
        configWatcher.close();
        configWatcher = null;
    }
    log('All file watchers closed', 'closeAllWatchers');
}

process.on('SIGTERM', () => {
    log('Received SIGTERM, shutting down...', 'SIGTERM');
    closeAllWatchers();
    process.exit(0);
});

process.on('SIGINT', () => {
    log('Received SIGINT, shutting down...', 'SIGINT');
    closeAllWatchers();
    process.exit(0);
});

const logsDir = path.join('private', 'logs');
const lastAssistantMessageFile = path.join('private', 'last-assistant-message.txt');
const CLAUDE_WINDOW_PATTERN = 'claude --dangerously-skip-permissions';
const WHISPER_SERVER_URL = 'http://localhost:5050';
let currentSessionFile = null;
let currentSessionNumber = 0;
let activeSocket = null;

let lastDiffSent = null;
let lastDiffHash = null;
let diffDebounceTimer = null;
const COLUMNS_JSON_PATH = path.join(require('os').homedir(), '.git-diff-columns.json');
const REPO_CONFIG_PATH = path.join(require('os').homedir(), '.watched-repo');

let claudeIsActive = false;
let lastActivitySentTime = 0;

const MAX_AUDIO_DURATION = 10;
const MAX_AUDIO_BYTES = MAX_AUDIO_DURATION * 16000 * 4;

const MAX_SUMMARY_CHARS = 50;
const MAX_CONTEXT_EVENTS = 20;
const MAX_SPEAK_LENGTH = 25;

const assistantSummaryCache = [];
const MAX_SUMMARY_CACHE_SIZE = 5;

let haikuContext = [];

let stateWatcher = null;
let conversationWatcher = null;
let gitDiffWatcher = null;

const messageStates = new Map();


const haikuPriorityQueue = {
    queue: [],
    isProcessing: false,

    add(priority, task, description) {
        const queuedTask = { priority, task, description };
        this.queue.push(queuedTask);
        this.queue.sort((a, b) => a.priority - b.priority);
        log(`[QUEUE] Added: ${description} (priority ${priority})`, 'haikuPriorityQueue.add');
        log(`[QUEUE] Current queue size: ${this.queue.length}`, 'haikuPriorityQueue.add');

        if (!this.isProcessing) {
            this.processNext();
        }
    },

    async processNext() {
        if (this.queue.length === 0) {
            this.isProcessing = false;
            log(`[QUEUE] Empty - stopping processor`, 'haikuPriorityQueue.processNext');
            return;
        }

        this.isProcessing = true;
        const { priority, task, description } = this.queue.shift();

        log(`[QUEUE] Processing: ${description} (priority ${priority})`, 'haikuPriorityQueue.processNext');
        log(`[QUEUE] Remaining in queue: ${this.queue.length}`, 'haikuPriorityQueue.processNext');

        try {
            await task();
        } catch (err) {
            error(`[QUEUE] Task failed: ${description} - ${err.message}`, 'haikuPriorityQueue.processNext');
        }

        this.processNext();
    }
};

function getMessageState(messageId) {
    if (!messageId) {
        log('No messageId provided', 'getMessageState');
        return null;
    }

    if (!messageStates.has(messageId)) {
        log(`Creating new message state for ID: ${messageId}`, 'getMessageState');
        messageStates.set(messageId, {
            messageId: messageId,
            audioBuffer: Buffer.alloc(0),
            isTranscribing: false,
            isRecordingAudio: false,
            shortTranscription: '',
            completeTranscription: '',
            deleted: false,
            injected: false,
            audioEnded: false
        });
    }

    return messageStates.get(messageId);
}

function addToContext(event) {
    haikuContext.push({
        ...event,
        timestamp: Date.now()
    });
    if (haikuContext.length > MAX_CONTEXT_EVENTS) {
        haikuContext.shift();
    }
    log(`Context: ${haikuContext.length} events`, 'addToContext');
}

function formatContextForHaiku() {
    if (haikuContext.length === 0) return "No previous context.";

    return haikuContext.map((e, i) => {
        switch (e.type) {
            case 'transcription':
                return `[${i + 1}] TRANSCRIPTION: "${e.text}"`;
            case 'corrected':
                return `[${i + 1}] CORRECTED: "${e.raw}" → "${e.corrected}"`;
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

function buildPrompt(text, task, completeTranscription = null) {
    const cleanText = text.replace(/[\n\r]+/g, ' ').replace(/\s+/g, ' ').trim();
    const context = formatContextForHaiku();

    const completeTranscriptionText = completeTranscription
        ? `\n\nCOMPLETE TRANSCRIPTION WITH TIMESTAMPS:\n${completeTranscription}`
        : '';

    if (task === 'correct_transcription') {
        return `You are a transcription processor for a voice-controlled coding assistant.

CONTEXT (last ${haikuContext.length} events):
${context}${completeTranscriptionText}

TASK: Correct transcription errors
INPUT (without timestamps): "${cleanText}"

INSTRUCTIONS:
Fix any speech-to-text errors based on context. Common issues: misheard technical terms, homophones, incomplete words.
${completeTranscription ? '\nNOTE: You have the complete transcription with timestamps showing when each segment was spoken. Use this for context if needed.' : ''}

OUTPUT: Respond with valid JSON only, no markdown, no explanation:
{"corrected": "the corrected text or original if no correction needed"}`;
    } else {
        return `You are a transcription processor for a voice-controlled coding assistant.

CONTEXT (last ${haikuContext.length} events):
${context}

TASK: Create summary
INPUT: "${cleanText}"

INSTRUCTIONS:
Create a brief summary (under ${MAX_SPEAK_LENGTH} characters) describing what this prompt is asking for.

OUTPUT: Respond with valid JSON only, no markdown, no explanation:
{"summary": "short summary under ${MAX_SPEAK_LENGTH} chars"}`;
    }
}

async function processWithHaiku(text, task, completeTranscription = null) {
    const cleanText = text.replace(/[\n\r]+/g, ' ').replace(/\s+/g, ' ').trim();

    log(`Haiku ${task}: "${cleanText.substring(0, 60)}..."`, 'processWithHaiku');

    const MAX_ATTEMPTS = 5;
    let attempt = 0;

    while (attempt < MAX_ATTEMPTS) {
        attempt++;
        try {
            const retryNote = attempt > 1 ? ` (attempt ${attempt}/${MAX_ATTEMPTS})` : '';
            log(`Processing${retryNote}...`, 'processWithHaiku');

            const prompt = buildPrompt(text, task, completeTranscription);

            const result = await new Promise((resolve, reject) => {
                const worker = new Worker(path.join(__dirname, 'haiku-worker.js'), {
                    workerData: { prompt, task }
                });

                worker.on('message', (msg) => {
                    if (msg.success) {
                        resolve(msg.result);
                    } else {
                        reject(new Error(msg.error));
                    }
                });

                worker.on('error', reject);
            });

            if (!result) {
                throw new Error('claude command returned empty output');
            }

            const cleanedResult = result.replace(/```json\n?/g, '').replace(/```\n?/g, '').trim();

            let parsed;
            try {
                parsed = JSON.parse(cleanedResult);
            } catch (parseErr) {
                log(`Invalid JSON: ${cleanedResult.substring(0, 100)}`, 'processWithHaiku');
                addToContext({ type: 'summary_attempt', result: cleanedResult, chars: cleanedResult.length, success: false, error: 'invalid_json' });
                continue;
            }

            const summary = parsed.summary || '';
            const corrected = parsed.corrected || cleanText;

            if (task === 'correct_transcription') {
                log(`Corrected: "${corrected.substring(0, 50)}..."`, 'processWithHaiku');
                return { corrected };
            } else {
                if (summary.length > MAX_SUMMARY_CHARS) {
                    log(`Summary too long: ${summary.length} chars`, 'processWithHaiku');
                    addToContext({ type: 'summary_attempt', result: summary, chars: summary.length, success: false, error: 'too_long' });
                    continue;
                }
                log(`Summary: "${summary}" (${summary.length} chars)`, 'processWithHaiku');
                addToContext({ type: 'summary_attempt', result: summary, chars: summary.length, success: true });
                return { summary };
            }

        } catch (err) {
            error(`Haiku failed: ${err.message}`, 'processWithHaiku');
            addToContext({ type: 'summary_attempt', result: err.message, chars: 0, success: false, error: 'exception' });
        }
    }

    log(`Max attempts reached, using fallback`, 'processWithHaiku');
    if (task === 'correct_transcription') {
        return { corrected: cleanText };
    } else {
        return { summary: cleanText.substring(0, MAX_SUMMARY_CHARS) };
    }
}

function deduplicateTranscription(newText, messageState, timestamp) {
    if (!newText || newText.trim().length === 0) {
        return messageState.shortTranscription;
    }

    if (!messageState.shortTranscription || messageState.shortTranscription.length === 0) {
        log(`First transcription - adding all text: "${newText}"`, 'deduplicateTranscription');
        messageState.completeTranscription = `${timestamp} ${newText}`;
        messageState.shortTranscription = newText;
        return newText;
    }

    const wordsSeen = new Set();
    for (const word of messageState.shortTranscription.split(/\s+/)) {
        wordsSeen.add(word.toLowerCase());
    }
    log(`Deduplicating "${newText}" against ${wordsSeen.size} words from accumulated text`, 'deduplicateTranscription');

    const newWords = [];
    for (const word of newText.split(/\s+/)) {
        if (!wordsSeen.has(word.toLowerCase())) {
            newWords.push(word);
        }
    }

    const uniqueText = newWords.join(' ').trim();

    if (uniqueText.length > 0) {
        log(`Adding unique words: "${uniqueText}"`, 'deduplicateTranscription');

        if (messageState.completeTranscription.length > 0) {
            messageState.completeTranscription += ' ';
        }
        messageState.completeTranscription += `${timestamp} ${uniqueText}`;

        if (messageState.shortTranscription.length > 0) {
            messageState.shortTranscription += ' ';
        }
        messageState.shortTranscription += uniqueText;
    } else {
        log(`No unique words to add`, 'deduplicateTranscription');
    }

    return messageState.shortTranscription;
}

async function transcribeAudio(audioPath) {
    if (IS_TEST && !MANUAL_TESTING) {
        log(`Automated testing: Skipping Whisper, returning mock "hello"`, 'transcribeAudio');
        return { text: 'hello', segments: [] };
    }

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

        log(`Lightning Whisper: ${result.elapsed_ms}ms server + ${elapsedMs - result.elapsed_ms}ms network = ${elapsedMs}ms total`, 'transcribeAudio');

        return {
            text: result.text,
            segments: result.segments || []
        };
    } catch (err) {
        throw new Error(`Transcription failed: ${err.message}`);
    }
}

async function handleAudioMessage(socket, logData) {
    const { audioData, isStart, isEnd, messageId } = logData;

    if (messageId) {
        const messageState = getMessageState(messageId);
        if (messageState && messageState.deleted) {
            log(`Skipping audio processing for deleted message: ${messageId}`, 'handleAudioMessage');
            return;
        }
    }

    if (isStart) {
        log('Audio recording started (embedded flag)', 'handleAudioMessage');
        if (!messageId) {
            log('No messageId provided for audio start', 'handleAudioMessage');
            return;
        }
        log(`Message ID: ${messageId}`, 'handleAudioMessage');

        const messageState = getMessageState(messageId);
        if (!messageState) return;

        messageState.audioBuffer = Buffer.alloc(0);
        messageState.isRecordingAudio = true;
        messageState.completeTranscription = '';
        messageState.shortTranscription = '';
        return;
    }

    if (isEnd) {
        log('AUDIO END: Setting audioEnded flag...', 'handleAudioMessage');
        const messageState = getMessageState(messageId);
        if (messageState) {
            messageState.audioEnded = true;
            log('audioEnded flag set to true', 'handleAudioMessage');
        }
        await triggerTranscription(messageId);
        return;
    }

    if (!audioData) {
        log('No audio data in message', 'handleAudioMessage');
        return;
    }

    if (!messageId) {
        log('No messageId provided for audio data', 'handleAudioMessage');
        return;
    }

    const messageState = getMessageState(messageId);
    if (!messageState) return;

    const newAudio = Buffer.from(audioData, 'base64');
    messageState.audioBuffer = Buffer.concat([messageState.audioBuffer, newAudio]);

    if (messageState.audioBuffer.length > MAX_AUDIO_BYTES) {
        messageState.audioBuffer = messageState.audioBuffer.slice(-MAX_AUDIO_BYTES);
    }

    if (messageState.isRecordingAudio && !messageState.isTranscribing && messageState.audioBuffer.length >= 16000) {
        triggerTranscription(messageId);
    }
}

async function triggerTranscription(messageId) {
    if (!messageId) {
        log('No messageId provided for transcription', 'triggerTranscription');
        return;
    }

    const messageState = getMessageState(messageId);
    if (!messageState) return;

    if (messageState.deleted) {
        log(`Skipping transcription for deleted message: ${messageId}`, 'triggerTranscription');
        return;
    }

    if (messageState.isTranscribing) {
        log('Transcription already in progress, waiting for completion...', 'triggerTranscription');
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

        if (text && activeSocket && messageState.isRecordingAudio) {
            log(`[RAW] Raw whisper: "${text}"`, 'triggerTranscription');

            const startTimeSeconds = messageState.audioBuffer.length / 16000;
            const minutes = Math.floor(startTimeSeconds / 60);
            const seconds = Math.floor(startTimeSeconds % 60);
            const timestamp = `[${minutes}:${seconds.toString().padStart(2, '0')}]`;

            deduplicateTranscription(text, messageState, timestamp);

            if (!messageState.shortTranscription || messageState.shortTranscription.trim().length === 0) {
                log(`Skipping (no unique words added)`, 'triggerTranscription');
                return;
            }

            if (activeSocket && messageState.isRecordingAudio) {
                if (messageState.deleted) {
                    log(`Skipping iOS send for deleted message: ${messageId}`, 'triggerTranscription');
                } else {
                    const rawTranscription = {
                        messageId: messageId,
                        timestamp: Date.now(),
                        type: 'transcription',
                        transcription: messageState.shortTranscription
                    };
                    log(`SENDING TO iOS: TRANSCRIPTION "${messageState.shortTranscription}" (messageId: ${messageId})`, 'triggerTranscription');
                    activeSocket.write(JSON.stringify(rawTranscription) + '\n');
                }
            }

            addToContext({ type: 'transcription', text: messageState.completeTranscription });
        }
    } catch (err) {
        error(`Interim transcription error: ${err.message}`, 'triggerTranscription');
    } finally {
        messageState.isTranscribing = false;

        if (messageState.audioEnded) {
            log('Audio has ended - triggering final processing...', 'triggerTranscription');
            await handleAudioEnd(messageId);
        }
    }
}

async function handleAudioEnd(messageId) {
    log('Audio recording stopped (embedded flag)', 'handleAudioEnd');

    if (!messageId) {
        log('No messageId provided for audio end', 'handleAudioEnd');
        return;
    }

    const messageState = getMessageState(messageId);
    if (!messageState) return;

    if (messageState.deleted) {
        log(`Skipping final processing for deleted message: ${messageId}`, 'handleAudioEnd');
        return;
    }

    messageState.isRecordingAudio = false;

    log(`Final concatenated text: "${messageState.shortTranscription}"`, 'handleAudioEnd');

    if (!messageState.shortTranscription || messageState.shortTranscription.trim().length === 0) {
        log('No concatenated text, skipping final processing', 'handleAudioEnd');
        return;
    }

    try {
        if (activeSocket && !messageState.deleted) {
            const rawTranscription = {
                messageId: messageId,
                timestamp: Date.now(),
                type: 'transcription',
                transcription: messageState.shortTranscription
            };
            log(`SENDING TO iOS: TRANSCRIPTION "${messageState.shortTranscription}" (messageId: ${messageId})`, 'handleAudioEnd');
            activeSocket.write(JSON.stringify(rawTranscription) + '\n');
        }

        addToContext({ type: 'transcription', text: messageState.completeTranscription });

        haikuPriorityQueue.add(1, async () => {
            try {
                log(`PRIORITY 1: Running Haiku correction on COMPLETE text...`, 'handleAudioEnd');
                log(`SENDING TO HAIKU: "${messageState.shortTranscription}"`, 'handleAudioEnd');

                const result = await processWithHaiku(messageState.shortTranscription, 'correct_transcription', messageState.completeTranscription);

                const corrected = result.corrected;

                log(`Got correction from Haiku: "${corrected}"`, 'handleAudioEnd');

                messageState.prompt = corrected;
                addToContext({ type: 'corrected', raw: messageState.completeTranscription, corrected: corrected });

                log(`[FINAL] Raw: "${messageState.shortTranscription}"`, 'handleAudioEnd');
                log(`[FINAL] Corrected: "${corrected}"`, 'handleAudioEnd');

                if (activeSocket && !messageState.deleted) {
                    const promptMessage = {
                        messageId: messageId,
                        timestamp: Date.now(),
                        type: 'prompt',
                        prompt: corrected
                    };
                    log(`SENDING TO iOS: PROMPT UPDATE "${corrected}" (messageId: ${messageId})`, 'handleAudioEnd');
                    activeSocket.write(JSON.stringify(promptMessage) + '\n');
                }

                log(`Injecting corrected transcription: "${corrected}"`, 'handleAudioEnd');
                if (!messageState.deleted) {
                    if (messageState.injected) {
                        log('Skipping injection - already injected for this message', 'handleAudioEnd');
                    } else {
                        injectIntoTerminal(corrected, (success, err) => {
                            if (success) {
                                log('Prompt injection successful', 'handleAudioEnd');
                                messageState.injected = true;
                            } else {
                                error(`Prompt injection failed: ${err}`, 'handleAudioEnd');
                            }
                        });
                    }
                }
            } catch (err) {
                error(`Haiku correction failed: ${err.message}`, 'handleAudioEnd');
            }
        }, `Prompt correction for "${messageState.shortTranscription.substring(0, 30)}..."`);

        haikuPriorityQueue.add(2, async () => {
            try {
                log(`PRIORITY 2: Creating summary...`, 'handleAudioEnd');

                const result = await processWithHaiku(messageState.shortTranscription, 'create_summary');

                const summary = result.summary;

                log(`Got summary from Haiku: "${summary}"`, 'handleAudioEnd');

                messageState.summary = summary;

                if (activeSocket && !messageState.deleted) {
                    const summaryMessage = {
                        messageId: messageId,
                        timestamp: Date.now(),
                        type: 'summary',
                        summary: summary
                    };
                    log(`SENDING TO iOS: SUMMARY "${summary}" (messageId: ${messageId})`, 'handleAudioEnd');
                    activeSocket.write(JSON.stringify(summaryMessage) + '\n');
                }
            } catch (err) {
                error(`Summary creation failed: ${err.message}`, 'handleAudioEnd');
            }
        }, `User message summary for "${messageState.shortTranscription.substring(0, 30)}..."`);

    } catch (err) {
        error(`Final transcription error: ${err.message}`, 'handleAudioEnd');
    }
}

function isAudioMessage(logData) {
    return logData.type === 'audio';
}

function isDeleteMessage(logData) {
    return logData.type === 'delete';
}

function handleDeleteMessage(logData) {
    const messageId = logData.messageId;

    if (!messageId) {
        log('Delete message received without messageId', 'handleDeleteMessage');
        return;
    }

    log(`DELETE MESSAGE: Received delete request for messageId: ${messageId}`, 'handleDeleteMessage');

    const messageState = getMessageState(messageId);
    if (messageState) {
        messageState.deleted = true;
        log(`Marked message as deleted: ${messageId}`, 'handleDeleteMessage');
    } else {
        log(`No message state found for messageId: ${messageId}`, 'handleDeleteMessage');
    }
}

const server = net.createServer((socket) => {
    log('iOS client connected', 'server');
    activeSocket = socket;

    const stateFile = path.join(__dirname, '..', 'private', 'claude-state.txt');
    if (fs.existsSync(stateFile)) {
        readClaudeState(stateFile);
    }

    let buffer = '';

    socket.on('data', (data) => {
        try {
            buffer += data.toString();
            buffer = processBufferedData(socket, buffer);
        } catch (err) {
            error(`Error processing data (continuing): ${err.message}`, 'socket.on.data');
        }
    });

    socket.on('end', () => {
        log('iOS client disconnected - waiting for reconnection...', 'socket.on.end');
        if (activeSocket === socket) {
            activeSocket = null;
            closeAllWatchers();
        }
    });

    socket.on('error', (err) => {
        error(`Socket error (continuing): ${err.message}`, 'socket.on.error');
    });
});

loadLastAssistantMessage();

server.listen(SERVER_PORT, '0.0.0.0', () => {
    log(`Mac server listening on :${SERVER_PORT} | ${getSessionCount()} sessions`, 'server.listen');

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
            } catch (err) {
                error(`Failed to parse JSON: ${err.message}, Line: ${line}`, 'processBufferedData');
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
    } else if (isDeleteMessage(logData)) {
        handleDeleteMessage(logData);
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
        log(`Speak rejected: ${summary.length} chars > ${MAX_SPEAK_LENGTH}`, 'handleSpeakMessage');
        return;
    }

    log(`Speaking: "${summary}" (full: "${(text || summary).substring(0, 50)}...")`, 'handleSpeakMessage');

    if (activeSocket) {
        const messageId = crypto.randomUUID();
        const assistantMessage = {
            messageId: messageId,
            timestamp: Date.now(),
            type: 'assistant',
            prompt: text || summary,
            summary: summary
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
    error(`Unknown message type: ${logData.type}`, 'handleUnknownMessage');
}

async function handleStartMessage(socket) {
    createNewSession();
    const stats = gatherSessionStatistics();
    await sendHandshakeResponse(socket, stats);
    logHandshakeDetails(stats);
}

function findLatestConversationFile(dir) {
    try {
        log(`Checking for conversation files in: ${dir}`, 'findLatestConversationFile');

        if (!fs.existsSync(dir)) {
            log(`Directory doesn't exist: ${dir}`, 'findLatestConversationFile');
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
            log(`No conversation files found in: ${dir}`, 'findLatestConversationFile');
            return null;
        }

        const latestFile = files[0];
        const modTime = new Date(latestFile.mtime).toLocaleString();
        log(`Found latest conversation: ${latestFile.name} (modified: ${modTime})`, 'findLatestConversationFile');
        return latestFile.path;
    } catch (e) {
        error(`Error finding conversation file in ${dir}: ${e.message}`, 'findLatestConversationFile');
        return null;
    }
}


function handlePromptMessage(socket, logData) {
    const { prompt, timestamp, messageId } = logData;
    log(`Received prompt from iOS app:`, 'handlePromptMessage');
    log(`   Prompt: "${prompt}"`, 'handlePromptMessage');
    log(`   Timestamp: ${new Date(timestamp * 1000).toLocaleString()}`, 'handlePromptMessage');
    log(`   MessageId: ${messageId}`, 'handlePromptMessage');

    promptCounter++;
    const promptId = `${promptCounter}:`;
    log(`Assigned ID: ${promptId}`, 'handlePromptMessage');

    if (prompt === '[Request interrupted by user]') {
        log('Detected stop signal - sending ESC instead of typing text', 'handlePromptMessage');

        switchToWindow(CLAUDE_WINDOW_PATTERN, (switchSuccess, switchError) => {
            if (!switchSuccess) {
                log(`Failed to switch to Claude Code window: ${switchError}`, 'handlePromptMessage');
                log(`Proceeding with interrupt anyway...`, 'handlePromptMessage');
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

                log('ESC key sent to Terminal', 'handlePromptMessage');

                const ackMessage = {
                    messageId: messageId,
                    timestamp: Date.now(),
                    type: 'prompt_ack',
                    status: 'success',
                    summary: ''
                };

                socket.write(JSON.stringify(ackMessage) + '\n');
                log('Interrupt acknowledged to iOS!', 'handlePromptMessage');
            } catch (err) {
                log(`Failed to send ESC: ${err.message}`, 'handlePromptMessage');

                const ackMessage = {
                    messageId: messageId,
                    timestamp: Date.now(),
                    type: 'prompt_ack',
                    status: 'error',
                    summary: '',
                    error: `Failed to send ESC: ${err.message}`
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
        messageId: messageId,
        timestamp: Date.now(),
        verified: false
    });
    log(`Added prompt to tracking (${pendingPrompts.size} total)`, 'handlePromptMessage');

    const promptWithId = `${promptId} ${prompt}`;
    log(`Injecting with ID: "${promptWithId}"`, 'handlePromptMessage');

    injectIntoTerminal(promptWithId, (terminalSuccess, terminalError) => {
        if (terminalSuccess) {
            log('Terminal automation executed successfully!', 'handlePromptMessage');
        } else {
            log(`Terminal automation failed: ${terminalError}`, 'handlePromptMessage');

            const ackMessage = {
                messageId: messageId,
                timestamp: Date.now(),
                type: 'prompt_ack',
                status: 'error',
                summary: '',
                error: `Terminal automation failed: ${terminalError}`
            };

            const jsonData = JSON.stringify(ackMessage) + '\n';
            socket.write(jsonData);
            log('Sent Terminal failure acknowledgment', 'handlePromptMessage');

            pendingPrompts.delete(promptId);
        }
    });
}

function createNewSession() {
    try {
        currentSessionNumber = getSessionCount() + 1;
        currentSessionFile = path.join(logsDir, `${currentSessionNumber}.json`);
        fs.writeFileSync(currentSessionFile, '');
    } catch (err) {
        error(`Failed to create session file (continuing): ${err.message}`, 'createNewSession');
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
    let apiKey;
    if (IS_TEST && !MANUAL_TESTING) {
        apiKey = 'test-api-key';
    } else if (MANUAL_TESTING) {
        apiKey = fs.readFileSync('/Users/felixlunzenfichter/Documents/realtime-claude/private/secrets.txt', 'utf8').trim();
    } else {
        apiKey = fs.readFileSync(path.join('private', 'secrets.txt'), 'utf8').trim();
    }

    const previousErrors = getPreviousSessionErrors(stats.sessionNumber);

    const crypto = require('crypto');
    const handshakeMessageId = lastSentAssistantMessage ? crypto.randomUUID() : null;

    const handshakeResponse = JSON.stringify({
        type: 'handshake',
        sessionNumber: stats.sessionNumber,
        totalUptime: stats.totalUptime,
        todayUptime: stats.todayUptime,
        totalLogs: stats.totalLogs,
        apiKey: apiKey,
        previousErrors: previousErrors,
        currentAssistantMessage: lastSentAssistantMessage,
        currentAssistantMessageSummary: "",
        messageId: handshakeMessageId
    }) + '\n';

    socket.write(handshakeResponse);

    sendGitDiffToiOS(true);

    if (previousErrors.length > 0) {
        log(`Sent ${previousErrors.length} previous error(s) to iOS app`, 'sendHandshakeResponse');
    }

    if (lastSentAssistantMessage) {
        log(`Handshake includes assistant message: ${lastSentAssistantMessage.substring(0, 100)}...`, 'sendHandshakeResponse');
        log(`Summary pending...`, 'sendHandshakeResponse');

        haikuPriorityQueue.add(3, async () => {
            try {
                log(`Creating handshake summary...`, 'sendHandshakeResponse');

                const result = await processWithHaiku(lastSentAssistantMessage, 'create_summary');

                const summary = result.summary;

                log(`Got handshake summary from Haiku: "${summary}"`, 'sendHandshakeResponse');

                const summaryUpdate = JSON.stringify({
                    type: 'handshake',
                    sessionNumber: stats.sessionNumber,
                    totalUptime: stats.totalUptime,
                    todayUptime: stats.todayUptime,
                    totalLogs: stats.totalLogs,
                    apiKey: apiKey,
                    previousErrors: previousErrors,
                    currentAssistantMessage: lastSentAssistantMessage,
                    currentAssistantMessageSummary: summary,
                    messageId: handshakeMessageId
                }) + '\n';

                if (activeSocket) {
                    activeSocket.write(summaryUpdate);
                    log(`Handshake summary update sent: "${summary}"`, 'sendHandshakeResponse');
                }
            } catch (err) {
                error(`Failed to create handshake summary: ${err.message}`, 'sendHandshakeResponse');
            }
        }, `Handshake assistant summary for "${lastSentAssistantMessage.substring(0, 30)}..."`);
    } else {
        log(`Handshake sent with no assistant message (null)`, 'sendHandshakeResponse');
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
    } catch (err) {
        error(`Failed to read previous session errors: ${err.message}`, 'getPreviousSessionErrors');
        return [];
    }
}

function logHandshakeDetails(stats) {
    log(`Sent handshake with session number: ${stats.sessionNumber}`, 'logHandshakeDetails');
    log(`Included stats - Total: ${stats.totalUptime}ms, Today: ${stats.todayUptime}ms, Logs: ${stats.totalLogs}`, 'logHandshakeDetails');
}

function handleLogMessage(socket, logData) {
    debugLog(`Received log: ${logData.message}`);
    persistLogToFile(logData);
    sendAcknowledgment(socket, logData.id);
}

function handleErrorMessage(socket, logData) {
    reportErrorToConsole(logData);
    persistLogToFile(logData);
    sendAcknowledgment(socket, logData.id);

    if (logData.message === "Manual restart triggered from log view") {
        executeDeployment();
    }
}

function reportErrorToConsole(logData) {
    error(`${logData.message} [${logData.fileName}:${logData.functionName}]`, 'reportErrorToConsole');
}

function persistLogToFile(logData) {
    writeLogToFile(logData);
}

function getSessionCount() {
    const files = fs.readdirSync(logsDir);
    return files.filter(f => f.endsWith('.json')).length;
}

function writeLogToFile(logData) {
    if (!currentSessionFile) {
        console.error('No active session file!');
        return;
    }
    try {
        fs.appendFileSync(currentSessionFile, JSON.stringify(logData) + '\n');
    } catch (err) {
        console.error(`Failed to write log (continuing): ${err.message}`);
    }
}

function sendAcknowledgment(socket, logId) {
    try {
        socket.write(JSON.stringify({ type: 'ack', logId: logId }) + '\n');
    } catch (err) {
        debugLog(`Failed to send ACK: ${err.message}`);
    }
}

let pendingPrompts = new Map();
let promptCounter = 0;

function loadLastAssistantMessage() {
    try {
        if (fs.existsSync(lastAssistantMessageFile)) {
            lastSentAssistantMessage = fs.readFileSync(lastAssistantMessageFile, 'utf8');
            log(`Loaded last assistant message from disk: ${lastSentAssistantMessage.substring(0, 80)}...`, 'loadLastAssistantMessage');
        } else {
            log('No previous assistant message found', 'loadLastAssistantMessage');
        }
    } catch (err) {
        error(`Failed to load last assistant message: ${err.message}`, 'loadLastAssistantMessage');
    }
}

function saveLastAssistantMessage(message) {
    try {
        fs.writeFileSync(lastAssistantMessageFile, message, 'utf8');
    } catch (err) {
        error(`Failed to save last assistant message: ${err.message}`, 'saveLastAssistantMessage');
    }
}

function initializeClaudeMonitoring() {
    const claudeProjectsPath = path.join(process.env.HOME, '.claude', 'projects');
    const stateFile = path.join(__dirname, '..', 'private', 'claude-state.txt');

    log(`Initializing Claude monitoring...`, 'initializeClaudeMonitoring');
    log(`   Projects path: ${claudeProjectsPath}`, 'initializeClaudeMonitoring');
    log(`   State file: ${stateFile}`, 'initializeClaudeMonitoring');
    log(`   State file exists: ${fs.existsSync(stateFile)}`, 'initializeClaudeMonitoring');

    stateWatcher = chokidar.watch(stateFile, {
        persistent: true,
        ignoreInitial: false
    });

    stateWatcher.on('add', (filePath) => {
        log(`[STATE] File added: ${filePath}`, 'initializeClaudeMonitoring');
        log(`   Calling readClaudeState`, 'initializeClaudeMonitoring');
        readClaudeState(filePath);
    });

    stateWatcher.on('change', (filePath) => {
        log(`[STATE] File changed: ${filePath}`, 'initializeClaudeMonitoring');
        log(`   Calling readClaudeState`, 'initializeClaudeMonitoring');
        readClaudeState(filePath);
    });

    stateWatcher.on('error', (err) => {
        error(`[STATE] Watcher error: ${err}`, 'initializeClaudeMonitoring');
    });

    stateWatcher.on('ready', () => {
        log(`[STATE] State watcher active on ${stateFile}`, 'initializeClaudeMonitoring');
    });

    conversationWatcher = chokidar.watch(claudeProjectsPath, {
        persistent: true,
        ignoreInitial: true,
        recursive: true,
        depth: 5,
        awaitWriteFinish: {
            stabilityThreshold: 2000,
            pollInterval: 500
        }
    });

    conversationWatcher.on('change', (filePath) => {
        if (filePath.endsWith('.jsonl')) {
            const conversationId = path.basename(filePath, '.jsonl');
            log(`[CONVERSATION] conversationId=${conversationId}`, 'initializeClaudeMonitoring');
            checkForInjectedPrompts(filePath);
        }
    });

    conversationWatcher.on('error', (err) => {
        error(`[CONVERSATION] Watcher error: ${err}`, 'initializeClaudeMonitoring');
    });

    conversationWatcher.on('ready', () => {
        log(`[CONVERSATION] Conversation watcher active on ${claudeProjectsPath}`, 'initializeClaudeMonitoring');
    });
}

function getRepoPath() {
    try {
        if (fs.existsSync(REPO_CONFIG_PATH)) {
            return fs.readFileSync(REPO_CONFIG_PATH, 'utf8').trim();
        }
    } catch (err) {
        error(`Failed to read repo config: ${err.message}`, 'getRepoPath');
    }
    return null;
}

function getRepoFingerprint(repoPath) {
    try {
        const head = execSync('git rev-parse HEAD', { cwd: repoPath, encoding: 'utf8' }).trim();
        const porcelain = execSync('git status --porcelain', { cwd: repoPath, encoding: 'utf8' });
        const crypto = require('crypto');
        return crypto.createHash('md5').update(head + porcelain).digest('hex');
    } catch (err) {
        return null;
    }
}

function computeColumns(text) {
    const LINE_WIDTH = 100;
    const MIN_ROWS = 100;
    const MAX_COLS = 20;

    const lines = text.split('\n');

    const wrapped = [];
    for (const line of lines) {
        if (line.length > LINE_WIDTH) {
            for (let i = 0; i < line.length; i += LINE_WIDTH) {
                wrapped.push(line.slice(i, i + LINE_WIDTH));
            }
        } else {
            wrapped.push(line);
        }
    }

    let numCols = Math.ceil(wrapped.length / MIN_ROWS);
    let numRows = MIN_ROWS;

    if (numCols > MAX_COLS) {
        numCols = MAX_COLS;
        numRows = Math.ceil(wrapped.length / MAX_COLS);
    }

    const columns = [];
    for (let i = 0; i < numCols; i++) {
        const col = wrapped.slice(i * numRows, (i + 1) * numRows);
        while (col.length < numRows) {
            col.push('');
        }
        columns.push(col.join('\n'));
    }

    return columns;
}

function writeColumnsJson(hash, columns) {
    const data = {
        hash: hash,
        timestamp: Date.now(),
        columns: columns
    };
    try {
        fs.writeFileSync(COLUMNS_JSON_PATH, JSON.stringify(data, null, 2));
        log(`Wrote ${columns.length} columns to ${COLUMNS_JSON_PATH}`, 'writeColumnsJson');
    } catch (err) {
        error(`Failed to write columns JSON: ${err.message}`, 'writeColumnsJson');
    }
}

let configWatcher = null;
let currentWatchedRepo = null;

function startRepoWatcher(repoPath) {
    if (gitDiffWatcher) {
        gitDiffWatcher.close();
        gitDiffWatcher = null;
        log(`Closed previous repo watcher`, 'startRepoWatcher');
    }

    currentWatchedRepo = repoPath;

    gitDiffWatcher = chokidar.watch(repoPath, {
        persistent: true,
        ignoreInitial: false,
        depth: 5,
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
            stabilityThreshold: 300,
            pollInterval: 200
        }
    });

    gitDiffWatcher.on('all', (event, filePath) => {
        if (diffDebounceTimer) {
            clearTimeout(diffDebounceTimer);
        }

        diffDebounceTimer = setTimeout(() => {
            sendGitDiffToiOS();
        }, 500);
    });

    gitDiffWatcher.on('error', (err) => {
        error(`Git diff watcher error: ${err}`, 'startRepoWatcher');
    });

    gitDiffWatcher.on('ready', () => {
        log(`Git diff monitoring active on ${repoPath}`, 'startRepoWatcher');
        sendGitDiffToiOS();
    });
}

function initializeGitDiffWatcher() {
    const repoPath = getRepoPath();
    if (repoPath) {
        startRepoWatcher(repoPath);
    } else {
        log(`No repo configured yet. Waiting for ${REPO_CONFIG_PATH}`, 'initializeGitDiffWatcher');
    }

    configWatcher = chokidar.watch(REPO_CONFIG_PATH, {
        persistent: true,
        ignoreInitial: true
    });

    configWatcher.on('change', () => {
        const newRepoPath = getRepoPath();
        if (newRepoPath && newRepoPath !== currentWatchedRepo) {
            log(`Config changed: switching to ${newRepoPath}`, 'initializeGitDiffWatcher');
            startRepoWatcher(newRepoPath);
        }
    });

    configWatcher.on('add', () => {
        const newRepoPath = getRepoPath();
        if (newRepoPath && !currentWatchedRepo) {
            log(`Config created: watching ${newRepoPath}`, 'initializeGitDiffWatcher');
            startRepoWatcher(newRepoPath);
        }
    });

    log(`Watching config file: ${REPO_CONFIG_PATH}`, 'initializeGitDiffWatcher');
}


function readClaudeState(filePath) {
    try {
        const fileContent = fs.readFileSync(filePath, 'utf8').trim();
        if (!fileContent) {
            log(`State file is empty`, 'readClaudeState');
            return;
        }

        const lines = fileContent.split('\n').filter(line => line.trim());
        if (lines.length === 0) {
            log(`State file has no valid lines`, 'readClaudeState');
            return;
        }

        const lastLine = lines[lines.length - 1];
        const parts = lastLine.split('|');

        if (parts.length !== 2) {
            log(`Invalid state line format: ${lastLine}`, 'readClaudeState');
            return;
        }

        const [state, timestampStr] = parts;
        const timestamp = parseInt(timestampStr, 10);

        log(`readClaudeState: "${state}" at ${timestamp}`, 'readClaudeState');

        if (state === 'stopped' || state === 'finished') {
            claudeIsActive = false;

            if (activeSocket) {
                const stateMessage = {
                    type: 'claude_state',
                    state: 'idle',
                    isActive: false,
                    timestamp: Date.now()
                };
                activeSocket.write(JSON.stringify(stateMessage) + '\n');
                lastActivitySentTime = Date.now();
                log(`Sent idle state to iOS (from "${state}")`, 'readClaudeState');
            } else {
                log(`No active socket - cannot send state to iOS`, 'readClaudeState');
            }
        } else {
            log(`Unknown state: "${state}"`, 'readClaudeState');
        }
    } catch (err) {
        error(`Error reading Claude state: ${err.message}`, 'readClaudeState');
    }
}

function sendGitDiffToiOS(force = false) {
    const repoPath = getRepoPath();
    if (!repoPath) {
        log(`No repo configured, skipping git diff`, 'sendGitDiffToiOS');
        return;
    }

    const hash = getRepoFingerprint(repoPath);
    if (!force && hash && hash === lastDiffHash) {
        return;
    }

    const os = require('os');
    const scriptPath = path.join(__dirname, 'get-diff.sh');
    const outputFile = path.join(os.tmpdir(), `git-diff-${Date.now()}-${process.pid}.txt`);

    try {
        execSync(`"${scriptPath}" > "${outputFile}" 2>&1`, {
            stdio: 'ignore',
            shell: '/bin/bash',
            timeout: 5000,
            cwd: repoPath
        });

        const diff = fs.readFileSync(outputFile, 'utf8').trim();

        if (!force && diff === lastDiffSent) {
            return;
        }

        lastDiffSent = diff;
        lastDiffHash = hash;

        const columns = computeColumns(diff);
        writeColumnsJson(hash, columns);

        if (activeSocket) {
            const diffMessage = {
                type: 'code_diff',
                diff: columns.join('\n\n--- COLUMN ---\n\n'),
                columns: columns,
                timestamp: Date.now()
            };

            const jsonData = JSON.stringify(diffMessage) + '\n';
            activeSocket.write(jsonData);

            log(`Sent git diff to iOS: ${columns.length} columns${force ? ' (forced during handshake)' : ''}`, 'sendGitDiffToiOS');
        }
    } catch (err) {
        log(`Failed to get git diff: ${err.message}`, 'sendGitDiffToiOS');
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
        let hasConversationActivity = false;

        for (const line of lines) {
            try {
                const event = JSON.parse(line);

                if (event.type === 'user' &&
                    event.message &&
                    event.message.role === 'user' &&
                    event.message.content) {

                    hasConversationActivity = true;

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

                    hasConversationActivity = true;
                    const stopReason = event.message.stop_reason;

                    if (typeof event.message.content === 'string') {
                        allAssistantEvents.push({
                            text: event.message.content,
                            timestamp: event.timestamp,
                            stopReason: stopReason
                        });
                    }
                    else if (Array.isArray(event.message.content)) {
                        for (const content of event.message.content) {
                            if (content.type === 'text' &&
                                content.text &&
                                typeof content.text === 'string') {
                                allAssistantEvents.push({
                                    text: content.text,
                                    timestamp: event.timestamp,
                                    stopReason: stopReason
                                });
                            }
                        }
                    }
                }
            } catch (parseErr) {
                continue;
            }
        }

        if (hasConversationActivity && activeSocket && allAssistantEvents.length > 0) {
            const now = Date.now();
            const latestAssistant = allAssistantEvents[allAssistantEvents.length - 1];
            const isActive = latestAssistant.stopReason === null || latestAssistant.stopReason === 'tool_use';

            if (now - lastActivitySentTime > 3000) {
                const stateMessage = {
                    type: 'claude_state',
                    isActive: isActive
                };
                activeSocket.write(JSON.stringify(stateMessage) + '\n');
                lastActivitySentTime = now;
                log(`Sent claude_state isActive=${isActive} (stop_reason: ${latestAssistant.stopReason})`, 'checkForInjectedPrompts');
            } else {
                log(`Skipping claude_state (debounced - stop_reason: ${latestAssistant.stopReason})`, 'checkForInjectedPrompts');
            }
        }

        const userEvents = allUserEvents.slice(-5);

        const lastMessage = userEvents.length > 0 ? userEvents[userEvents.length - 1].text.substring(0, 100).replace(/\n/g, ' ') : 'none';

        if (allUserEvents.length > 0) {
            const lastUserEvent = allUserEvents[allUserEvents.length - 1];

            if (lastUserEvent.text.includes('interrupted by user') ||
                lastUserEvent.text.includes('Request interrupted by user')) {

                log(`Detected interrupt message in last user message: "${lastUserEvent.text.substring(0, 80)}..."`, 'checkForInjectedPrompts');

                if (activeSocket) {
                    const stateMessage = {
                        type: 'claude_state',
                        state: 'idle',
                        isActive: false,
                        timestamp: Date.now()
                    };
                    activeSocket.write(JSON.stringify(stateMessage) + '\n');
                    lastActivitySentTime = Date.now();
                    log(`Sent idle state to iOS (from interrupt detection)`, 'checkForInjectedPrompts');
                }
            }
        }

        for (const [promptId, data] of pendingPrompts.entries()) {
            if (!data.verified) {
                log(`Checking pending prompt ID: ${promptId}`, 'checkForInjectedPrompts');
                log(`   Original prompt: "${data.originalPrompt.substring(0, 60)}..."`, 'checkForInjectedPrompts');

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
                    log(`MATCH FOUND in message [${matchedIndex + 1}] of last 5 user messages!`, 'checkForInjectedPrompts');
                    log(`   Found ID: ${promptId}`, 'checkForInjectedPrompts');
                    log(`   Message preview: "${matchedEvent.text.substring(0, 80).replace(/\n/g, ' ')}..."`, 'checkForInjectedPrompts');
                    log(`Found in conversation events: ${path.basename(filePath)}`, 'checkForInjectedPrompts');

                    data.verified = true;
                    data.verifiedAt = Date.now();

                    if (activeSocket) {
                        sendPromptAckWithSummary(data.originalPrompt, data.messageId);
                    }

                    pendingPrompts.delete(promptId);
                } else {
                    log(`ID ${promptId} NOT FOUND in last 5 user messages`, 'checkForInjectedPrompts');
                    log(`   Prompt may not have appeared in conversation yet`, 'checkForInjectedPrompts');
                }
            }
        }

        const verifiedCount = Array.from(pendingPrompts.values()).filter(p => p.verified).length;
        const pendingCount = pendingPrompts.size - verifiedCount;

        if (pendingCount > 0) {
            log(`Pending prompts:`, 'checkForInjectedPrompts');
            let index = 1;
            for (const [promptId, data] of pendingPrompts.entries()) {
                if (!data.verified) {
                    log(`   [${index}] ID: ${promptId}`, 'checkForInjectedPrompts');
                    log(`       Prompt: "${data.originalPrompt.substring(0, 100)}..."`, 'checkForInjectedPrompts');
                    log(`       Age: ${Math.round((Date.now() - data.timestamp) / 1000)}s`, 'checkForInjectedPrompts');
                    index++;
                }
            }
        }

        // Check for new assistant messages to send to iOS
        if (allAssistantEvents.length > 0) {
            const latestAssistant = allAssistantEvents[allAssistantEvents.length - 1];

            // Filter out messages from the summary system itself
            const looksLikeJSON = latestAssistant.text.trim().startsWith('```json');

            if (looksLikeJSON) {
                log(`Ignoring assistant message - looks like JSON/summary response`, 'checkForInjectedPrompts');
                log(`   Filtered content: "${latestAssistant.text}"`, 'checkForInjectedPrompts');
            } else if (latestAssistant.text !== lastSentAssistantMessage) {
                log(`New assistant message detected: "${latestAssistant.text.substring(0, 80)}..."`, 'checkForInjectedPrompts');

                lastSentAssistantMessage = latestAssistant.text;
                saveLastAssistantMessage(latestAssistant.text);

                sendAssistantMessageToiOS(latestAssistant.text);
            }
        }

    } catch (err) {
        error(`Error checking file ${filePath}: ${err.message}`, 'checkForInjectedPrompts');
    }
}

async function sendPromptAckWithSummary(originalPrompt, messageId) {
    let extractedSummary = null;

    const jsonMatch = originalPrompt.match(/\{\s*"summary"\s*:\s*"([^"]*)"\s*\}/);
    if (jsonMatch) {
        extractedSummary = jsonMatch[1];
        log(`Extracted embedded summary from user prompt: "${extractedSummary}"`, 'sendPromptAckWithSummary');
    }

    log('Prompt verified in conversation', 'sendPromptAckWithSummary');

    if (extractedSummary) {
        log('Using embedded summary - sending immediately', 'sendPromptAckWithSummary');

        const summaryMessage = {
            messageId: messageId,
            timestamp: Date.now(),
            type: 'summary',
            summary: extractedSummary
        };

        activeSocket.write(JSON.stringify(summaryMessage) + '\n');
        log(`Sent summary to iOS: "${extractedSummary}"`, 'sendPromptAckWithSummary');
        addToContext({ type: 'user_message', text: originalPrompt, summary: extractedSummary });
        return;
    }

    log('Queueing Haiku for summary generation...', 'sendPromptAckWithSummary');

    haikuPriorityQueue.add(2, async () => {
        try {
            log(`Creating prompt summary...`, 'sendPromptAckWithSummary');

            const result = await processWithHaiku(originalPrompt, 'create_summary');

            const summary = result.summary;

            log(`Got prompt summary from Haiku: "${summary}"`, 'sendPromptAckWithSummary');

            addToContext({ type: 'user_message', text: originalPrompt, summary: summary });

            const summaryMessage = {
                messageId: messageId,
                timestamp: Date.now(),
                type: 'summary',
                summary: summary
            };

            if (activeSocket) {
                activeSocket.write(JSON.stringify(summaryMessage) + '\n');
                log(`Sent summary to iOS: "${summary}"`, 'sendPromptAckWithSummary');
            }
        } catch (err) {
            error(`Failed to create prompt summary: ${err.message}`, 'sendPromptAckWithSummary');
            addToContext({ type: 'user_message', text: originalPrompt, summary: null });
        }
    }, `User prompt summary for "${originalPrompt.substring(0, 30)}..."`);
}

async function sendAssistantMessageToiOS(text) {
    if (!activeSocket) {
        log('No iOS client connected - skipping', 'sendAssistantMessageToiOS');
        return;
    }

    try {
        const cachedEntry = assistantSummaryCache.find(entry => entry.text === text);

        if (cachedEntry) {
            log(`Message already in cache - already processed and sent, skipping`, 'sendAssistantMessageToiOS');
            return;
        }

        const messageId = crypto.randomUUID();
        assistantSummaryCache.push({ text: text, summary: "", messageId: messageId });
        if (assistantSummaryCache.length > MAX_SUMMARY_CACHE_SIZE) {
            assistantSummaryCache.shift();
        }

        const assistantMessage = {
            messageId: messageId,
            timestamp: Date.now(),
            type: 'assistant',
            prompt: text,
            summary: ""
        };

        activeSocket.write(JSON.stringify(assistantMessage) + '\n');
        log(`Assistant message sent to iOS: "${text.substring(0, 80)}..."`, 'sendAssistantMessageToiOS');

        log('Assistant message queued for summary generation...', 'sendAssistantMessageToiOS');

        haikuPriorityQueue.add(3, async () => {
            try {
                log(`Creating assistant message summary...`, 'sendAssistantMessageToiOS');

                const result = await processWithHaiku(text, 'create_summary');

                const summary = result.summary;

                log(`Created new summary: "${summary}"`, 'sendAssistantMessageToiOS');

                const cacheEntry = assistantSummaryCache.find(entry => entry.text === text);
                if (cacheEntry) {
                    cacheEntry.summary = summary;
                }

                addToContext({ type: 'assistant_message', text: text, summary: summary });

                const summaryUpdate = {
                    messageId: cacheEntry?.messageId || messageId,
                    timestamp: Date.now(),
                    type: 'assistant',
                    prompt: text,
                    summary: summary
                };

                if (activeSocket) {
                    activeSocket.write(JSON.stringify(summaryUpdate) + '\n');
                    log(`Summary update sent: "${summary}"`, 'sendAssistantMessageToiOS');
                }
            } catch (err) {
                error(`Failed to summarize assistant message: ${err.message}`, 'sendAssistantMessageToiOS');
            }
        }, `Assistant message summary for "${text.substring(0, 30)}..."`);
    } catch (err) {
        error(`Failed to send assistant message: ${err.message}`, 'sendAssistantMessageToiOS');
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
            log('Deployment already in progress, skipping duplicate restart', 'executeDeployment');
            return;
        }
    } catch (error) {
    } finally {
        try { fs.unlinkSync(outputFile); } catch {}
    }

    log('Executing deployment in scripts window...', 'executeDeployment');

    const scriptOutputFile = path.join(os.tmpdir(), `deploy-out-${Date.now()}-${process.pid}.txt`);

    try {
        execSync('./scripts/deploy-in-window.sh > "' + scriptOutputFile + '" 2>&1 &', {
            stdio: 'ignore',
            shell: '/bin/bash',
            timeout: 1000
        });

        log('Deployment process spawned and detached', 'executeDeployment');
    } catch (err) {
        error(`Failed to spawn deployment: ${err.message}`, 'executeDeployment');
    } finally {
        try { fs.unlinkSync(scriptOutputFile); } catch {}
    }
}

function switchToWindow(windowNamePattern, callback) {
    log(`Switching to Terminal window containing: "${windowNamePattern}"`, 'switchToWindow');

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
            log(`   ${result}`, 'switchToWindow');
            callback(false, result);
        } else {
            log(`   ${result}`, 'switchToWindow');
            callback(true);
        }
    } catch (err) {
        log(`   Failed to switch window: ${err.message}`, 'switchToWindow');
        callback(false, err.message);
    } finally {
        try { fs.unlinkSync(scriptFile); } catch {}
        try { fs.unlinkSync(outputFile); } catch {}
    }
}

function injectIntoTerminal(prompt, callback) {
    const escapedPrompt = prompt
        .replace(/"/g, '')
        .replace(/'/g, '');

    log(`Injecting prompt into Terminal: "${escapedPrompt}"`, 'injectIntoTerminal');

    switchToWindow(CLAUDE_WINDOW_PATTERN, (switchSuccess, switchError) => {
        if (!switchSuccess) {
            log(`Failed to switch to Claude Code window: ${switchError}`, 'injectIntoTerminal');
            log(`Proceeding with injection anyway...`, 'injectIntoTerminal');
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

        log('Executing enhanced AppleScript for macOS 26 Tahoe...', 'injectIntoTerminal');

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

            log('AppleScript result:', 'injectIntoTerminal');
            if (result.includes('error:')) {
                log(`   Output: ${result}`, 'injectIntoTerminal');
                callback(false, result);
            } else {
                log(`   Success: ${result}`, 'injectIntoTerminal');
                callback(true);
            }
        } catch (err) {
            log(`   Error: ${err.message}`, 'injectIntoTerminal');
            log(`   Note: Ensure Terminal has Accessibility permissions in System Settings`, 'injectIntoTerminal');
            callback(false, `AppleScript error: ${err.message}`);
        } finally {
            try { fs.unlinkSync(scriptFile); } catch {}
            try { fs.unlinkSync(outputFile); } catch {}
        }
    });
}
