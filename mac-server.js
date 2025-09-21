const net = require('net');
const fs = require('fs');
const path = require('path');

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
    let lines = buffer.split('\n');
    buffer = lines.pop() || '';

    for (const line of lines) {
        if (line.trim()) {
            const jsonData = JSON.parse(line);
            handleMessage(socket, jsonData);
        }
    }

    return buffer;
}

function handleMessage(socket, logData) {
    if (isStartMessage(logData)) {
        handleStartMessage(socket);
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
    const handshakeResponse = JSON.stringify({
        type: 'handshake',
        sessionNumber: stats.sessionNumber,
        totalUptime: stats.totalUptime,
        todayUptime: stats.todayUptime,
        totalLogs: stats.totalLogs
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
    console.log('Wrote log with ID:', logData.id);
}

function confirmLogReception(socket, logId) {
    sendAcknowledgment(socket, logId);
    console.log('Sent ACK for log ID:', logId);
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