const { execSync, spawn } = require('child_process');
const fs = require('fs');

const TMUX_SESSION_NAME = 'haiku-conversation';
const RESPONSE_MARKER_START = '___HAIKU_RESPONSE_START___';
const RESPONSE_MARKER_END = '___HAIKU_RESPONSE_END___';
const OUTPUT_FILE = '/tmp/haiku-tmux-output.txt';
const POLL_INTERVAL_MS = 100;
const MAX_WAIT_MS = 30000;

function invariantTmuxSession() {
    const exists = sessionExists();
    if (!exists) {
        throw new Error(`INV: tmux session '${TMUX_SESSION_NAME}' does not exist`);
    }
}

function preconditionSendPrompt(prompt) {
    if (!prompt || prompt.trim() === '') {
        throw new Error('PRE: sendPrompt prompt is empty');
    }
    invariantTmuxSession();
}

function postconditionSendPrompt(response) {
    if (!response || response.trim() === '') {
        throw new Error('POST: sendPrompt returned empty response');
    }
    invariantTmuxSession();
}

function sessionExists() {
    try {
        execSync(`tmux has-session -t ${TMUX_SESSION_NAME} 2>/dev/null`, {
            stdio: ['pipe', 'pipe', 'pipe']
        });
        return true;
    } catch {
        return false;
    }
}

function createSession() {
    if (sessionExists()) {
        return;
    }

    execSync(`tmux new-session -d -s ${TMUX_SESSION_NAME} -x 200 -y 50`, {
        stdio: ['pipe', 'pipe', 'pipe']
    });

    execSync(`tmux send-keys -t ${TMUX_SESSION_NAME} 'claude --model haiku --verbose' Enter`, {
        stdio: ['pipe', 'pipe', 'pipe']
    });

    let ready = false;
    const startTime = Date.now();
    while (!ready && (Date.now() - startTime) < 10000) {
        const output = capturePane();
        if (output.includes('>') || output.includes('Claude')) {
            ready = true;
        } else {
            execSync('sleep 0.5', { stdio: ['pipe', 'pipe', 'pipe'] });
        }
    }

    if (!ready) {
        throw new Error('Claude CLI did not start within timeout');
    }
}

function capturePane() {
    try {
        const output = execSync(`tmux capture-pane -t ${TMUX_SESSION_NAME} -p -S -1000`, {
            encoding: 'utf8',
            stdio: ['pipe', 'pipe', 'pipe']
        });
        return output;
    } catch {
        return '';
    }
}

function sendKeys(text) {
    const escaped = text
        .replace(/\\/g, '\\\\')
        .replace(/"/g, '\\"')
        .replace(/\$/g, '\\$')
        .replace(/`/g, '\\`');

    execSync(`tmux send-keys -t ${TMUX_SESSION_NAME} "${escaped}"`, {
        stdio: ['pipe', 'pipe', 'pipe']
    });
}

function sendEnter() {
    execSync(`tmux send-keys -t ${TMUX_SESSION_NAME} Enter`, {
        stdio: ['pipe', 'pipe', 'pipe']
    });
}

async function sendPromptAndWaitForResponse(prompt) {
    preconditionSendPrompt(prompt);

    const wrappedPrompt = `Please wrap your ENTIRE response between these exact markers (include them in your output):
${RESPONSE_MARKER_START}
<your response here>
${RESPONSE_MARKER_END}

Now process this:
${prompt}`;

    const paneBefore = capturePane();
    const linesBefore = paneBefore.split('\n').length;

    sendKeys(wrappedPrompt);
    sendEnter();

    const startTime = Date.now();
    let response = null;

    while ((Date.now() - startTime) < MAX_WAIT_MS) {
        await new Promise(resolve => setTimeout(resolve, POLL_INTERVAL_MS));

        const paneContent = capturePane();

        const startIdx = paneContent.lastIndexOf(RESPONSE_MARKER_START);
        const endIdx = paneContent.lastIndexOf(RESPONSE_MARKER_END);

        if (startIdx !== -1 && endIdx !== -1 && endIdx > startIdx) {
            response = paneContent
                .substring(startIdx + RESPONSE_MARKER_START.length, endIdx)
                .trim();
            break;
        }
    }

    if (!response) {
        throw new Error('Timeout waiting for Haiku response');
    }

    postconditionSendPrompt(response);
    return response;
}

function killSession() {
    if (sessionExists()) {
        execSync(`tmux kill-session -t ${TMUX_SESSION_NAME}`, {
            stdio: ['pipe', 'pipe', 'pipe']
        });
    }
}

function ensureSession() {
    if (!sessionExists()) {
        createSession();
    }
}

module.exports = {
    TMUX_SESSION_NAME,
    sessionExists,
    createSession,
    ensureSession,
    sendPromptAndWaitForResponse,
    killSession,
    capturePane
};
