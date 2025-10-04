const net = require('net');
const fs = require('fs');
const path = require('path');
const { exec } = require('child_process');

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

const server = net.createServer((socket) => {
    console.log('iOS client connected');

    let buffer = '';

    socket.on('data', (data) => {
        buffer += data.toString();
        buffer = processBufferedData(socket, buffer);
    });

    socket.on('end', () => {
        console.log('iOS client disconnected');
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
    const { prompt, category, timestamp } = logData;
    console.log(`\n📨 Received prompt from iOS app:`);
    console.log(`   Category: ${category}`);
    console.log(`   Prompt: "${prompt}"`);
    console.log(`   Timestamp: ${new Date(timestamp * 1000).toLocaleString()}`);

    // Clean the prompt - remove quotation marks and escape backslashes
    const cleanedPrompt = prompt
        .replace(/["']/g, '')  // Remove quotes
        .replace(/\\/g, '\\\\');  // Escape backslashes for AppleScript
    console.log(`🧹 Cleaned prompt: "${cleanedPrompt}"`);

    // Use Terminal automation (macOS 26 enhanced method)
    console.log('\n🚀 Attempting Terminal automation (macOS 26 enhanced method)...');
    injectIntoTerminal(cleanedPrompt, (terminalSuccess, terminalError) => {
        if (terminalSuccess) {
            console.log('✅ Terminal automation executed successfully!');
            console.log('🔍 Verifying prompt in conversation file...');

            // Wait and verify the prompt actually appears in the conversation
            // Use the Documents directory where Claude is currently running
            const conversationDir = '/Users/felixlunzenfichter/.claude/projects/-Users-felixlunzenfichter-Documents';
            const convFile = findLatestConversationFile(conversationDir);

            if (!convFile) {
                console.log(`❌ No conversation file found for verification of prompt: '${cleanedPrompt}'`);
                sendFailureAck(`Failed to inject prompt: '${cleanedPrompt}' - No conversation file found`);
                return;
            }

            // Wait 2 seconds then verify
            setTimeout(() => {
                try {
                    const fileContent = fs.readFileSync(convFile, 'utf8');
                    const lines = fileContent.split('\n').filter(line => line.trim());
                    const lastLines = lines.slice(-50);

                    let foundInConversation = false;
                    for (const line of lastLines) {
                        try {
                            const json = JSON.parse(line);
                            if (json.message && json.message.content) {
                                const contentStr = JSON.stringify(json.message.content);

                                if (contentStr.includes(cleanedPrompt)) {
                                    foundInConversation = true;
                                    console.log('✅ Verified: Prompt found in conversation!');
                                    break;
                                }
                            }
                        } catch (e) {
                            // Ignore JSON parse errors
                        }
                    }

                    if (foundInConversation) {
                        // Send success acknowledgment
                        const ackMessage = {
                            type: 'prompt_ack',
                            status: 'success',
                            method: 'terminal_automation',
                            originalPrompt: prompt,
                            timestamp: Date.now()
                        };

                        const jsonData = JSON.stringify(ackMessage) + '\n';
                        socket.write(jsonData);

                        console.log('📤 Sent success acknowledgment to iOS app');
                        console.log('🎉 Prompt successfully injected via Terminal automation!');
                    } else {
                        console.log(`❌ Terminal automation executed but prompt not found in conversation: '${cleanedPrompt}'`);
                        sendFailureAck(`Failed to inject prompt: '${cleanedPrompt}' - Prompt not found in conversation after Terminal automation`);
                    }
                } catch (error) {
                    console.error(`❌ Error verifying Terminal automation for prompt: '${cleanedPrompt}'`, error.message);
                    sendFailureAck(`Failed to inject prompt: '${cleanedPrompt}' - Verification error: ${error.message}`);
                }
            }, 2000);
        } else {
            console.log(`❌ Terminal automation failed for prompt: '${cleanedPrompt}' - Error: ${terminalError}`);
            sendFailureAck(`Failed to inject prompt: '${cleanedPrompt}' - Terminal automation failed: ${terminalError}`);
        }
    });

    // Helper function to send failure acknowledgment
    function sendFailureAck(errorMessage) {
        const ackMessage = {
            type: 'prompt_ack',
            status: 'error',
            error: errorMessage,
            originalPrompt: prompt,
            timestamp: Date.now()
        };

        const jsonData = JSON.stringify(ackMessage) + '\n';
        socket.write(jsonData);

        console.log('📤 Sent failure acknowledgment to iOS app');
        console.error('❌ Failed to inject prompt:', errorMessage);
    }
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

                keystroke return

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