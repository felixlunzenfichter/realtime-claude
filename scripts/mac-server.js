const net = require('net');
const fs = require('fs');
const path = require('path');
const { exec } = require('child_process');
const chokidar = require('chokidar');

process.on('uncaughtException', (error) => {
    console.error(`💥 FATAL: Mac Server crashed! ${error}\n❌ Server must be reliable - this is unacceptable!`);
    process.exit(1);
});

process.on('unhandledRejection', (reason, promise) => {
    console.error(`💥 FATAL: Unhandled promise rejection! ${reason}\n❌ All promises must be handled - exiting!`);
    process.exit(1);
});

const logsDir = path.join('private', 'logs');
let currentSessionFile = null;
let currentSessionNumber = 0;
let activeSocket = null;

const server = net.createServer((socket) => {
    console.log('iOS client connected');
    activeSocket = socket;

    let buffer = '';

    socket.on('data', (data) => {
        buffer += data.toString();
        buffer = processBufferedData(socket, buffer);
    });

    socket.on('end', () => {
        console.log('iOS client disconnected');
        if (activeSocket === socket) {
            activeSocket = null;
        }
    });

    socket.on('error', (err) => {
        console.log('Socket error:', err.message);
    });
});

server.listen(8082, '0.0.0.0', () => {
    console.log('Mac server listening on port 8082');
    console.log('Waiting for iOS connections...');
    console.log('Logs directory:', logsDir);
    console.log('Existing sessions:', getSessionCount());

    // Initialize Claude conversation monitoring
    initializeClaudeMonitoring();
});

function processBufferedData(socket, buffer) {
    let messagesProcessed = 0;
    let remainingBuffer = buffer;

    // Process ALL complete messages in the buffer
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

function handleMessage(socket, logData) {
    if (isStartMessage(logData)) {
        handleStartMessage(socket);
    } else if (isPromptMessage(logData)) {
        handlePromptMessage(socket, logData);
    } else if (isErrorMessage(logData)) {
        handleErrorMessage(socket, logData);
    } else if (isLogMessage(logData)) {
        handleLogMessage(socket, logData);
    } else {
        handleUnknownMessage(logData);
    }
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

function handleStartMessage(socket) {
    createNewSession();
    const stats = gatherSessionStatistics();
    sendHandshakeResponse(socket, stats);
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
    console.log(`\n📨 Received prompt from iOS app:`);
    console.log(`   Prompt: "${prompt}"`);
    console.log(`   Timestamp: ${new Date(timestamp * 1000).toLocaleString()}`);

    // Clean the prompt - remove quotation marks and escape backslashes
    const cleanedPrompt = prompt
        .replace(/["']/g, '')  // Remove quotes
        .replace(/\\/g, '\\\\');  // Escape backslashes for AppleScript
    console.log(`🧹 Cleaned prompt: "${cleanedPrompt}"`);

    // Store prompt WITHOUT socket reference
    pendingPrompts.set(cleanedPrompt, {
        originalPrompt: prompt,
        timestamp: Date.now(),
        verified: false
    });
    console.log(`📝 Added prompt to tracking (${pendingPrompts.size} total)`);

    // Check if this is the stop signal
    if (prompt === '[Request interrupted by user]') {
        console.log('🛑 Detected stop signal - sending ESC instead of typing text');

        // Send ESC key instead of typing the text
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
                pendingPrompts.delete(cleanedPrompt);
            } else {
                console.log('✅ ESC key sent to Terminal');
                // File watcher will automatically detect when the message appears
            }
        });

        return;  // Don't continue to normal injection
    }

    // Normal prompt injection for all other messages
    injectIntoTerminal(cleanedPrompt, (terminalSuccess, terminalError) => {
        if (terminalSuccess) {
            console.log('✅ Terminal automation executed successfully!');
            // File watcher will automatically detect when the prompt appears
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

            pendingPrompts.delete(cleanedPrompt);
        }
    });
}

function createNewSession() {
    currentSessionNumber = getSessionCount() + 1;
    currentSessionFile = path.join(logsDir, `${currentSessionNumber}.json`);
    fs.writeFileSync(currentSessionFile, '');
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

function sendHandshakeResponse(socket, stats) {
    const apiKey = fs.readFileSync(path.join('private', 'secrets.txt'), 'utf8').trim();

    const handshakeResponse = JSON.stringify({
        type: 'handshake',
        sessionNumber: stats.sessionNumber,
        totalUptime: stats.totalUptime,
        todayUptime: stats.todayUptime,
        totalLogs: stats.totalLogs,
        apiKey: apiKey
    }) + '\n';

    socket.write(handshakeResponse);
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
        console.error('No active session file!');
        return;
    }
    fs.appendFileSync(currentSessionFile, JSON.stringify(logData) + '\n');
}

function sendAcknowledgment(socket, logId) {
    const ackMessage = JSON.stringify({
        type: 'ack',
        logId: logId
    }) + '\n';

    socket.write(ackMessage);
}


// Global variables for prompt monitoring
let pendingPrompts = new Map(); // Map: cleanedPrompt -> {originalPrompt, timestamp, verified}

function initializeClaudeMonitoring() {
    const claudeProjectsPath = path.join(process.env.HOME, '.claude', 'projects');

    console.log('\n🔍 Initializing prompt detection monitoring...');
    console.log(`📁 Watching entire directory: ${claudeProjectsPath}`);

    const watcher = chokidar.watch(claudeProjectsPath, {
        persistent: true,
        ignoreInitial: true,
        recursive: true,
        depth: 99,
        awaitWriteFinish: {
            stabilityThreshold: 500,
            pollInterval: 100
        }
    });

    watcher.on('change', (filePath) => {
        console.log(`\n🔄 File changed: ${filePath}`);
        if (filePath.endsWith('.jsonl')) {
            console.log(`📝 Checking file for pending prompts...`);
            checkForInjectedPrompts(filePath);
        } else {
            console.log(`⏭️  Skipping non-jsonl file`);
        }
    });

    watcher.on('error', (error) => {
        console.error('❌ Watcher error:', error);
    });

    watcher.on('ready', () => {
        console.log('✅ Prompt monitoring active');
        console.log('📊 Watching for any file changes in entire directory tree...');
    });
}

function checkForInjectedPrompts(filePath) {
    try {
        // Read the entire file
        const fileContent = fs.readFileSync(filePath, 'utf8');
        const lines = fileContent.trim().split('\n');

        console.log(`\n📊 Total events in conversation: ${lines.length}`);

        // FIRST: Filter ALL events for user text messages
        const allUserEvents = [];
        for (const line of lines) {
            try {
                const event = JSON.parse(line);

                // Only process user events with actual text content
                if (event.type === 'user' &&
                    event.message &&
                    event.message.role === 'user' &&
                    event.message.content) {

                    // Handle TWO formats:
                    // Format 1: content is a STRING (newer format)
                    if (typeof event.message.content === 'string') {
                        allUserEvents.push({
                            text: event.message.content,
                            timestamp: event.timestamp
                        });
                    }
                    // Format 2: content is an ARRAY (older format)
                    else if (Array.isArray(event.message.content)) {
                        // Find text content in the message (exclude tool_result, tool_use, etc.)
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
            } catch (parseErr) {
                // Skip malformed lines
                continue;
            }
        }

        // SECOND: Take the last 5 relevant user messages
        const userEvents = allUserEvents.slice(-5);

        console.log(`📋 Found ${allUserEvents.length} total user text messages`);
        console.log(`🎯 Using last ${userEvents.length} user messages for verification\n`);

        console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
        console.log('📄 Last 5 user text messages:');
        console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
        userEvents.forEach((event, index) => {
            const preview = event.text.substring(0, 100).replace(/\n/g, ' ');
            console.log(`[${index + 1}] "${preview}${event.text.length > 100 ? '...' : ''}"`);
        });
        console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

        // Check each pending prompt against user events
        for (const [prompt, data] of pendingPrompts.entries()) {
            if (!data.verified) {
                console.log(`\n🔍 Checking pending prompt: "${prompt.substring(0, 60)}..."`);


                // Look for the prompt in user events and find which one matched
                let matchedIndex = -1;
                let matchedEvent = null;

                for (let i = 0; i < userEvents.length; i++) {
                    if (userEvents[i].text.includes(prompt)) {
                        matchedIndex = i;
                        matchedEvent = userEvents[i];
                        break;
                    }
                }

                if (matchedEvent) {
                    console.log(`✅ MATCH FOUND in message [${matchedIndex + 1}] of last 5 user messages!`);
                    console.log(`   Matched text: "${matchedEvent.text.substring(0, 80).replace(/\n/g, ' ')}..."`);
                    console.log(`   Prompt searched: "${prompt.substring(0, 80)}..."`);
                    console.log(`   ✓ Newly injected message IS part of the last 5 relevant messages`);
                    console.log('📍 Found in conversation events:', path.basename(filePath));

                    // Mark as verified
                    data.verified = true;
                    data.verifiedAt = Date.now();

                    // Send success acknowledgment
                    if (activeSocket) {
                        const ackMessage = {
                            type: 'prompt_ack',
                            status: 'success',
                            method: 'conversation_event_verification',
                            originalPrompt: data.originalPrompt,
                            timestamp: Date.now()
                        };

                        const jsonData = JSON.stringify(ackMessage) + '\n';
                        activeSocket.write(jsonData);
                        console.log('✅ Prompt verified and acknowledged to iOS!');
                    }

                    // Remove from tracking
                    pendingPrompts.delete(prompt);
                } else {
                    console.log(`❌ NOT FOUND in last 5 user messages`);
                    console.log(`   Prompt may not have appeared in conversation yet`);
                }
            }
        }

        // Report status with details
        const verifiedCount = Array.from(pendingPrompts.values()).filter(p => p.verified).length;
        const pendingCount = pendingPrompts.size - verifiedCount;

        console.log(`\n📊 Prompt Status: ${verifiedCount} verified, ${pendingCount} pending`);

        // Print pending prompt details
        if (pendingCount > 0) {
            console.log(`\n⏳ Pending prompts:`);
            let index = 1;
            for (const [prompt, data] of pendingPrompts.entries()) {
                if (!data.verified) {
                    console.log(`   [${index}] "${prompt.substring(0, 100)}..."`);
                    console.log(`       Original: "${data.originalPrompt.substring(0, 100)}..."`);
                    console.log(`       Age: ${Math.round((Date.now() - data.timestamp) / 1000)}s`);
                    index++;
                }
            }
        }

    } catch (err) {
        console.error(`❌ Error checking file ${filePath}:`, err.message);
    }
}

function injectIntoTerminal(prompt, callback) {
    // No escaping needed - prompt is already cleaned and escaped
    const escapedPrompt = prompt;

    console.log(`🔤 Injecting prompt into Terminal: "${escapedPrompt}"`);

    // Enhanced AppleScript for macOS 26 Tahoe - using heredoc for safety
    const appleScriptCommand = `osascript <<'EOF'
        -- First activate Terminal to bring it to front
        tell application "Terminal"
            activate
        end tell

        -- Short delay to ensure activation
        delay 0.2

        -- Use System Events for extra reliability
        tell application "System Events"
            tell process "Terminal"
                set frontmost to true

                -- Perform AXRaise action for additional window raising
                try
                    perform action "AXRaise" of window 1
                end try

                -- Now send keystrokes
                keystroke "${escapedPrompt}"

                -- Wait 1 second before pressing enter
                delay 1

                -- Send return key (Enter)
                key code 36

                return "success: Typed into Terminal (macOS 26 enhanced method)"
            end tell
        end tell
EOF`;

    console.log('🍎 Executing enhanced AppleScript for macOS 26 Tahoe...');

    // Execute the AppleScript using heredoc
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
}