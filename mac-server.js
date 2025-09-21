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
const testDir = path.join('private', 'test');
let currentSessionFile = null;
let currentSessionNumber = 0;


function getSessionCount() {
    const files = fs.readdirSync(logsDir);
    return files.filter(f => f.endsWith('.json')).length;
}

function computeUptimeStats() {
    const files = fs.readdirSync(logsDir).filter(f => f.endsWith('.json'));

    if (files.length === 0) {
        return { totalUptime: 0, todayUptime: 0 };
    }

    const today = new Date();
    today.setHours(0, 0, 0, 0);

    let totalUptime = 0;
    let todayUptime = 0;

    files.forEach(file => {
        const filePath = path.join(logsDir, file);
        const content = fs.readFileSync(filePath, 'utf8');
        const lines = content.split('\n').filter(line => line.trim());

        if (lines.length === 0) return;

        const firstLog = JSON.parse(lines[0]);
        const lastLog = JSON.parse(lines[lines.length - 1]);

        const startTime = new Date(firstLog.timestamp);
        const endTime = new Date(lastLog.timestamp);
        const duration = endTime - startTime;

        totalUptime += duration;

        if (startTime >= today) {
            todayUptime += duration;
        }
    });

    return {
        totalUptime: Math.floor(totalUptime),
        todayUptime: Math.floor(todayUptime)
    };
}

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
    if (logData.type === 'start') {
        handleStartMessage(socket);
    } else if ('error' in logData.type) {
        handleErrorMessage(socket, logData);
    } else if ('log' in logData.type) {
        handleLogMessage(socket, logData);
    } else {
        console.error('Unknown message type:', logData.type);
    }
}

function handleLogMessage(socket, logData) {
    console.log('Received log:', logData.message);
    writeLogToFile(logData);
    sendAcknowledgment(socket, logData.id);
}

function handleErrorMessage(socket, logData) {
    console.error(`🚨 ERROR: ${logData.message} [${logData.fileName}:${logData.functionName}] - test will fail`);
    writeLogToFile(logData);
    sendAcknowledgment(socket, logData.id);
}

function handleStartMessage(socket) {
    currentSessionNumber = getSessionCount() + 1;
    currentSessionFile = path.join(logsDir, `${currentSessionNumber}.json`);
    fs.writeFileSync(currentSessionFile, '');

    const uptimeStats = computeUptimeStats();

    let totalLogs = 0;
    fs.readdirSync(logsDir).filter(f => f.endsWith('.json')).forEach(file => {
        const content = fs.readFileSync(path.join(logsDir, file), 'utf8');
        totalLogs += content.split('\n').filter(line => line.trim()).length;
    });

    const handshakeResponse = JSON.stringify({
        type: 'handshake',
        sessionNumber: currentSessionNumber,
        totalUptime: uptimeStats.totalUptime,
        todayUptime: uptimeStats.todayUptime,
        totalLogs: totalLogs
    }) + '\n';

    socket.write(handshakeResponse);
    console.log('Sent handshake with session number:', currentSessionNumber);
    console.log('Included stats - Total:', uptimeStats.totalUptime + 'ms, Today:', uptimeStats.todayUptime + 'ms, Logs:', totalLogs);
}


function writeLogToFile(logData) {
    if (!currentSessionFile) {
        console.error('No active session file!');
        return;
    }
    fs.appendFileSync(currentSessionFile, JSON.stringify(logData) + '\n');
    console.log('Wrote log with ID:', logData.id);
}

function sendAcknowledgment(socket, logId) {
    const ackMessage = JSON.stringify({
        type: 'ack',
        logId: logId
    }) + '\n';

    socket.write(ackMessage);
    console.log('Sent ACK for log ID:', logId);
}

server.listen(8082, '0.0.0.0', () => {
    console.log('Mac server listening on port 8082');
    console.log('Waiting for iOS connections...');
    console.log('Logs directory:', logsDir);
    console.log('Existing sessions:', getSessionCount());
});