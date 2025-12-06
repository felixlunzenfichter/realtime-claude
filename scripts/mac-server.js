const net = require('net');
const fs = require('fs');
const path = require('path');
const { exec, spawn, execSync } = require('child_process');
const chokidar = require('chokidar');

process.on('uncaughtException', (error) => {
    console.error(`⚠️ Uncaught exception (continuing): ${error.stack || error}`);
});

process.on('unhandledRejection', (reason, promise) => {
    console.error(`⚠️ Unhandled promise rejection (continuing): ${reason}`);
});

const logsDir = path.join('private', 'logs');
const lastAssistantMessageFile = path.join('private', 'last-assistant-message.txt');
const CLAUDE_WINDOW_PATTERN = 'claude --dangerously-skip-permissions';
const WHISPER_MODEL = '/Users/felixlunzenfichter/.cache/huggingface/hub/whisper-large-v3-mlx-direct';
const WHISPER_VENV = '/Users/felixlunzenfichter/Documents/realtime-claude/whisper-venv-312';
let currentSessionFile = null;
let currentSessionNumber = 0;
let activeSocket = null;
let lastSentAssistantMessage = null;
let lastSentAssistantTimestamp = null;
let audioBuffer = Buffer.alloc(0);
let isTranscribing = false;
let lastTranscription = '';
let isRecordingAudio = false;
let pendingTranscription = false;

const MAX_SUMMARY_CHARS = 100;

async function summarizeWithClaude(text) {
    // Clean text for shell: remove newlines, normalize whitespace
    const cleanText = text.replace(/[\n\r]+/g, ' ').replace(/\s+/g, ' ').trim();

    let lastResult = null;
    let attempt = 0;

    console.log(`📝 Text to summarize (${cleanText.length} chars): "${cleanText.substring(0, 100)}..."`);

    const MAX_ATTEMPTS = 10;
    while (attempt < MAX_ATTEMPTS) {
        attempt++;
        try {
            const retryNote = attempt > 1 ? ` (attempt ${attempt}/${MAX_ATTEMPTS})` : '';
            console.log(`🤖 Summarizing with Claude Haiku${retryNote}...`);

            let prompt;
            if (attempt === 1 || lastResult === null) {
                prompt = `Summarize this text in under 50 characters. Output ONLY the summary, nothing else.

Text: "${cleanText}"

Summary:`;
            } else {
                prompt = `Your previous summary was ${lastResult.length} characters (too long). Summarize in UNDER 50 CHARACTERS. Output ONLY the summary, nothing else.

Text: "${cleanText}"

Summary:`;
            }

            // Write prompt to temp file to avoid shell escaping issues
            const tempFile = '/tmp/claude-prompt.txt';
            fs.writeFileSync(tempFile, prompt);

            // No session ID - each summarization is stateless
            let result = execSync(`cat "${tempFile}" | claude --model haiku --print -`, {
                encoding: 'utf8',
                timeout: 30000
            }).trim();

            lastResult = result;
            console.log(`   Result: "${result}" (${result.length} chars)`);

            if (result.length <= MAX_SUMMARY_CHARS) {
                return result;
            }

            console.log(`   ⚠️ Too long (${result.length} chars), retrying...`);

        } catch (error) {
            console.error(`   ❌ Claude headless failed: ${error.message}, retrying...`);
        }
    }

    // If all attempts failed, return the last result (even if too long) or a fallback
    console.log(`   ⚠️ Max attempts reached, using last result`);
    return lastResult || text.substring(0, MAX_SUMMARY_CHARS);
}

async function transcribeAudio(audioPath) {
    return new Promise((resolve, reject) => {
        const pythonScript = `
import mlx_whisper
import json
import sys

result = mlx_whisper.transcribe(
    "${audioPath}",
    path_or_hf_repo="${WHISPER_MODEL}"
)
print(json.dumps({"text": result["text"].strip()}))
`;
        const pythonPath = path.join(WHISPER_VENV, 'bin', 'python3');

        exec(`${pythonPath} -c '${pythonScript}'`, { timeout: 60000 }, (error, stdout, stderr) => {
            if (error) {
                reject(new Error(`Transcription failed: ${error.message}`));
                return;
            }
            try {
                const result = JSON.parse(stdout.trim());
                resolve(result.text);
            } catch (parseError) {
                reject(new Error(`Failed to parse transcription result: ${stdout}`));
            }
        });
    });
}

function handleAudioMessage(socket, logData) {
    const { audioData } = logData;

    if (!audioData) {
        console.log('⚠️ No audio data in message');
        return;
    }

    const newAudio = Buffer.from(audioData, 'base64');
    audioBuffer = Buffer.concat([audioBuffer, newAudio]);

    const durationSeconds = audioBuffer.length / (16000 * 4);

    if (isRecordingAudio && !isTranscribing && audioBuffer.length >= 16000) {
        triggerTranscription();
    }
}

async function triggerTranscription() {
    if (isTranscribing) {
        pendingTranscription = true;
        return;
    }

    isTranscribing = true;

    try {
        const tempFile = '/tmp/whisper_interim.wav';
        const audioData = Buffer.from(audioBuffer);

        await new Promise((resolve, reject) => {
            const ffmpeg = spawn('ffmpeg', [
                '-y', '-f', 'f32le', '-ar', '16000', '-ac', '1',
                '-i', 'pipe:0', tempFile
            ]);
            ffmpeg.stdin.write(audioData);
            ffmpeg.stdin.end();
            ffmpeg.on('close', (code) => {
                if (code === 0) resolve();
                else reject(new Error(`ffmpeg exited with code ${code}`));
            });
            ffmpeg.on('error', reject);
        });

        const text = await transcribeAudio(tempFile);

        if (text && text !== lastTranscription && activeSocket && isRecordingAudio) {
            lastTranscription = text;
            console.log(`🎤 [INTERIM] ${text}`);

            const transcription = {
                type: 'transcription',
                status: 'partial',
                text: text,
                timestamp: Date.now()
            };
            activeSocket.write(JSON.stringify(transcription) + '\n');
        }
    } catch (err) {
        console.error(`❌ Interim transcription error: ${err.message}`);
    } finally {
        isTranscribing = false;

        if (pendingTranscription && isRecordingAudio && audioBuffer.length >= 16000) {
            pendingTranscription = false;
            triggerTranscription();
        }
    }
}

async function handleAudioControlMessage(socket, logData) {
    const { action } = logData;

    if (action === 'start') {
        console.log('🎤 Audio recording started');
        audioBuffer = Buffer.alloc(0);
        lastTranscription = '';
        isRecordingAudio = true;
        pendingTranscription = false;
    } else if (action === 'stop') {
        console.log('🎤 Audio recording stopped, transcribing...');
        isRecordingAudio = false;
        pendingTranscription = false;

        if (audioBuffer.length < 16000) {
            console.log('⚠️ Audio too short, skipping transcription');
            return;
        }

        while (isTranscribing) {
            await new Promise(resolve => setTimeout(resolve, 50));
        }

        isTranscribing = true;

        try {
            const tempFile = '/tmp/whisper_audio.wav';
            const audioData = audioBuffer;

            await new Promise((resolve, reject) => {
                const ffmpeg = spawn('ffmpeg', [
                    '-y', '-f', 'f32le', '-ar', '16000', '-ac', '1',
                    '-i', 'pipe:0', tempFile
                ]);
                ffmpeg.stdin.write(audioData);
                ffmpeg.stdin.end();
                ffmpeg.on('close', (code) => {
                    if (code === 0) resolve();
                    else reject(new Error(`ffmpeg exited with code ${code}`));
                });
                ffmpeg.on('error', reject);
            });

            console.log('🎤 Transcribing audio...');
            const text = await transcribeAudio(tempFile);

            if (text) {
                lastTranscription = text;
                console.log(`🎤 [FINAL] ${text}`);

                if (activeSocket) {
                    const transcription = {
                        type: 'transcription',
                        status: 'final',
                        text: text,
                        timestamp: Date.now()
                    };
                    activeSocket.write(JSON.stringify(transcription) + '\n');
                }
            }
        } catch (err) {
            console.error(`❌ Transcription error: ${err.message}`);
        } finally {
            isTranscribing = false;
            audioBuffer = Buffer.alloc(0);
        }
    } else if (action === 'reset') {
        console.log('🎤 Audio reset');
        isRecordingAudio = false;
        stopInterimTranscription();
        audioBuffer = Buffer.alloc(0);
        lastTranscription = '';
    }
}

function isAudioMessage(logData) {
    return logData.type === 'audio';
}

function isAudioControlMessage(logData) {
    return logData.type === 'audio_control';
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
        handleAudioMessage(socket, logData);
    } else if (isAudioControlMessage(logData)) {
        await handleAudioControlMessage(socket, logData);
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

            const escapeCommand = `osascript <<'EOF'
                tell application "Terminal"
                    activate
                end tell

                delay 0.2

                tell application "System Events"
                    key code 53
                end tell
EOF`;

            exec(escapeCommand, (error, stdout, stderr) => {
                if (error) {
                    console.log(`❌ Failed to send ESC: ${error.message}`);

                    const ackMessage = {
                        type: 'prompt_ack',
                        status: 'error',
                        error: `Failed to send ESC: ${error.message}`,
                        originalPrompt: prompt,
                        timestamp: Date.now()
                    };

                    socket.write(JSON.stringify(ackMessage) + '\n');
                } else {
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
                }
            });
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
                lastSentAssistantTimestamp = latestAssistant.timestamp;
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
        // Send ack without summary as fallback
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
        const summary = await summarizeWithClaude(text);

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
    exec('pgrep -f "deploy-in-window.sh"', (error, stdout) => {
        if (stdout.trim()) {
            console.log('⚠️ Deployment already in progress, skipping duplicate restart');
            return;
        }

        console.log('🚀 Executing deployment in scripts window...');

        const child = spawn('./scripts/deploy-in-window.sh', [], {
            detached: true,
            stdio: 'ignore'
        });

        child.unref();
        console.log('✅ Deployment process spawned and detached');
    });
}

function switchToWindow(windowNamePattern, callback) {
    console.log(`🪟 Switching to Terminal window containing: "${windowNamePattern}"`);

    const appleScriptCommand = `osascript <<'EOF'
        tell application "Terminal"
            activate
            repeat with w from 1 to count of windows
                if name of window w contains "${windowNamePattern}" then
                    set index of window w to 1
                    return "success: Switched to window " & w
                end if
            end repeat
            return "error: No window found containing '${windowNamePattern}'"
        end tell
EOF`;

    exec(appleScriptCommand, (error, stdout, stderr) => {
        if (error) {
            console.log(`   ❌ Failed to switch window: ${error.message}`);
            callback(false, error.message);
        } else if (stdout.includes('error:')) {
            console.log(`   ❌ ${stdout.trim()}`);
            callback(false, stdout.trim());
        } else {
            console.log(`   ✅ ${stdout.trim()}`);
            callback(true);
        }
    });
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

        const appleScriptCommand = `osascript <<'EOF'
            tell application "Terminal"
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
            end tell
EOF`;

        console.log('🍎 Executing enhanced AppleScript for macOS 26 Tahoe...');

        exec(appleScriptCommand, (error, stdout, stderr) => {
            console.log('📝 AppleScript result:');
            if (error) {
                console.log(`   Error: ${error.message}`);
                console.log(`   Note: Ensure Terminal has Accessibility permissions in System Settings`);
                callback(false, `AppleScript error: ${error.message}`);
            } else if (stderr) {
                console.log(`   Stderr: ${stderr}`);
                callback(false, `AppleScript stderr: ${stderr}`);
            } else if (stdout.includes('error:')) {
                console.log(`   Output: ${stdout.trim()}`);
                callback(false, stdout.trim());
            } else {
                console.log(`   Success: ${stdout.trim()}`);
                callback(true);
            }
        });
    });
}

