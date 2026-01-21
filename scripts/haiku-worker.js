const { parentPort, workerData } = require('worker_threads');
const { execSync, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const { prompt, task, sessionId } = workerData;

const TMUX_SESSION_NAME = 'haiku-conversation';
const SESSION_FILE = '/tmp/haiku-session-id.txt';

function getOrCreateSessionId() {
    if (fs.existsSync(SESSION_FILE)) {
        return fs.readFileSync(SESSION_FILE, 'utf8').trim();
    }
    return null;
}

function saveSessionId(id) {
    fs.writeFileSync(SESSION_FILE, id);
}

try {
    const timestamp = Date.now();
    const inputFile = `/tmp/haiku-worker-${timestamp}.txt`;
    const outputFile = `/tmp/haiku-worker-${timestamp}-out.txt`;

    fs.writeFileSync(inputFile, prompt);

    const existingSessionId = getOrCreateSessionId();
    const sessionFlag = existingSessionId ? `--session-id ${existingSessionId}` : '';
    
    const cmd = `cat "${inputFile}" | claude --model haiku --print --output-format json ${sessionFlag} - > "${outputFile}" 2>&1`;
    
    execSync(cmd, {
        stdio: 'ignore',
        shell: '/bin/bash',
        timeout: 30000
    });

    const rawOutput = fs.readFileSync(outputFile, 'utf8').trim();

    fs.unlinkSync(inputFile);
    fs.unlinkSync(outputFile);

    const jsonResponse = JSON.parse(rawOutput);
    const result = jsonResponse.result;
    const returnedSessionId = jsonResponse.session_id;

    if (returnedSessionId && returnedSessionId !== existingSessionId) {
        saveSessionId(returnedSessionId);
    }

    parentPort.postMessage({ success: true, result, sessionId: returnedSessionId || TMUX_SESSION_NAME });
} catch (error) {
    parentPort.postMessage({ success: false, error: error.message });
}
