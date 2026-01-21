const { parentPort, workerData } = require('worker_threads');
const { execSync, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const { prompt, task, sessionId } = workerData;

const TMUX_SESSION_NAME = 'haiku-conversation';
const SESSION_FILE = '/tmp/haiku-session-id.txt';

function log(message, functionName = 'unknown') {
    console.log(`[haiku-worker] ${functionName}: ${message}`);
}

function error(message, functionName = 'unknown') {
    console.error(`[haiku-worker] ERROR ${functionName}: ${message}`);
}

function preconditionWorker(prompt, task) {
    if (!prompt) {
        error('PRE: prompt is null/undefined', 'preconditionWorker');
    }
    if (prompt && prompt.trim() === '') {
        error('PRE: prompt is empty', 'preconditionWorker');
    }
    if (!['correct_transcription', 'create_summary'].includes(task)) {
        error(`PRE: invalid task: ${task}`, 'preconditionWorker');
    }
    log(`PRE: worker OK - task=${task}, promptLen=${prompt ? prompt.length : 0}`, 'preconditionWorker');
}

function postconditionWorker(result, sessionId) {
    if (!result) {
        error('POST: result is null/undefined', 'postconditionWorker');
    }
    if (!sessionId) {
        error('POST: sessionId is null/undefined', 'postconditionWorker');
    }
    log(`POST: worker OK - resultLen=${result ? result.length : 0}, sessionId=${sessionId}`, 'postconditionWorker');
}

function preconditionClaudeCommand(inputFile, outputFile) {
    if (!fs.existsSync(inputFile)) {
        error(`PRE: input file does not exist: ${inputFile}`, 'preconditionClaudeCommand');
    }
    const inputContent = fs.readFileSync(inputFile, 'utf8');
    if (inputContent.trim() === '') {
        error('PRE: input file is empty', 'preconditionClaudeCommand');
    }
    log(`PRE: claude command OK - inputLen=${inputContent.length}`, 'preconditionClaudeCommand');
}

function postconditionClaudeCommand(outputFile) {
    if (!fs.existsSync(outputFile)) {
        error(`POST: output file does not exist: ${outputFile}`, 'postconditionClaudeCommand');
    }
    const outputContent = fs.readFileSync(outputFile, 'utf8');
    if (outputContent.trim() === '') {
        error('POST: output file is empty', 'postconditionClaudeCommand');
    }
    log(`POST: claude command OK - outputLen=${outputContent.length}`, 'postconditionClaudeCommand');
}

function preconditionParseResponse(rawOutput) {
    if (!rawOutput) {
        error('PRE: rawOutput is null/undefined', 'preconditionParseResponse');
    }
    if (rawOutput.trim() === '') {
        error('PRE: rawOutput is empty', 'preconditionParseResponse');
    }
    log(`PRE: parse response OK - rawLen=${rawOutput.length}`, 'preconditionParseResponse');
}

function postconditionParseResponse(jsonResponse) {
    if (!jsonResponse) {
        error('POST: jsonResponse is null', 'postconditionParseResponse');
    }
    if (!jsonResponse.result) {
        error('POST: jsonResponse.result is missing', 'postconditionParseResponse');
    }
    log(`POST: parse response OK - hasResult=${!!jsonResponse.result}, hasSessionId=${!!jsonResponse.session_id}`, 'postconditionParseResponse');
}

function getOrCreateSessionId() {
    if (fs.existsSync(SESSION_FILE)) {
        const id = fs.readFileSync(SESSION_FILE, 'utf8').trim();
        log(`Session ID loaded from file: ${id}`, 'getOrCreateSessionId');
        return id;
    }
    log('No existing session ID found', 'getOrCreateSessionId');
    return null;
}

function saveSessionId(id) {
    fs.writeFileSync(SESSION_FILE, id);
    log(`Session ID saved: ${id}`, 'saveSessionId');
}

log(`Worker started - task=${task}, promptLen=${prompt ? prompt.length : 0}`, 'main');
preconditionWorker(prompt, task);

try {
    const timestamp = Date.now();
    const inputFile = `/tmp/haiku-worker-${timestamp}.txt`;
    const outputFile = `/tmp/haiku-worker-${timestamp}-out.txt`;

    log(`Writing prompt to ${inputFile}`, 'main');
    fs.writeFileSync(inputFile, prompt);

    const existingSessionId = getOrCreateSessionId();
    const sessionFlag = existingSessionId ? `--session-id ${existingSessionId}` : '';
    
    const cmd = `cat "${inputFile}" | claude --model haiku --print --output-format json ${sessionFlag} - > "${outputFile}" 2>&1`;
    log(`Executing: ${cmd.substring(0, 100)}...`, 'main');
    
    preconditionClaudeCommand(inputFile, outputFile);
    
    const startTime = Date.now();
    execSync(cmd, {
        stdio: 'ignore',
        shell: '/bin/bash',
        timeout: 30000
    });
    const elapsed = Date.now() - startTime;
    log(`Claude command completed in ${elapsed}ms`, 'main');
    
    postconditionClaudeCommand(outputFile);

    const rawOutput = fs.readFileSync(outputFile, 'utf8').trim();
    log(`Raw output length: ${rawOutput.length}`, 'main');

    log(`Cleaning up temp files`, 'main');
    fs.unlinkSync(inputFile);
    fs.unlinkSync(outputFile);

    preconditionParseResponse(rawOutput);
    const jsonResponse = JSON.parse(rawOutput);
    postconditionParseResponse(jsonResponse);
    
    const result = jsonResponse.result;
    const returnedSessionId = jsonResponse.session_id;

    if (returnedSessionId && returnedSessionId !== existingSessionId) {
        log(`New session ID: ${returnedSessionId}`, 'main');
        saveSessionId(returnedSessionId);
    }

    postconditionWorker(result, returnedSessionId || TMUX_SESSION_NAME);
    
    log(`Posting success message - resultLen=${result ? result.length : 0}`, 'main');
    parentPort.postMessage({ success: true, result, sessionId: returnedSessionId || TMUX_SESSION_NAME });
} catch (err) {
    error(`Worker failed: ${err.message}`, 'main');
    error(`Stack: ${err.stack}`, 'main');
    parentPort.postMessage({ success: false, error: err.message });
}
