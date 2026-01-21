const { parentPort, workerData } = require('worker_threads');
const { execSync } = require('child_process');
const fs = require('fs');

const { prompt, task, sessionId } = workerData;

const TMUX_SESSION_NAME = 'haiku-conversation';
const RESPONSE_MARKER_START = '___HAIKU_RESPONSE_START___';
const RESPONSE_MARKER_END = '___HAIKU_RESPONSE_END___';
const POLL_INTERVAL_MS = 200;
const MAX_WAIT_MS = 30000;

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

    execSync(`tmux send-keys -t ${TMUX_SESSION_NAME} 'claude --model haiku --dangerously-skip-permissions' Enter`, {
        stdio: ['pipe', 'pipe', 'pipe']
    });

    let ready = false;
    const startTime = Date.now();
    while (!ready && (Date.now() - startTime) < 20000) {
        const output = capturePane();
        if (output.includes('>') || output.includes('?') || output.includes('shortcuts')) {
            ready = true;
        } else {
            execSync('sleep 0.5');
        }
    }

    if (!ready) {
        throw new Error('Claude CLI did not start within timeout');
    }
    
    execSync('sleep 1');
}

function capturePane() {
    try {
        const output = execSync(`tmux capture-pane -t ${TMUX_SESSION_NAME} -p -S -200`, {
            encoding: 'utf8',
            stdio: ['pipe', 'pipe', 'pipe']
        });
        return output;
    } catch {
        return '';
    }
}

function sendKeys(text) {
    const tempFile = `/tmp/haiku-prompt-${process.pid}.txt`;
    fs.writeFileSync(tempFile, text);
    
    execSync(`tmux load-buffer ${tempFile}`, {
        stdio: ['pipe', 'pipe', 'pipe']
    });
    
    execSync(`tmux paste-buffer -t ${TMUX_SESSION_NAME}`, {
        stdio: ['pipe', 'pipe', 'pipe']
    });
    
    try { fs.unlinkSync(tempFile); } catch {}
}

function sendEnter() {
    execSync(`tmux send-keys -t ${TMUX_SESSION_NAME} Enter`, {
        stdio: ['pipe', 'pipe', 'pipe']
    });
}

function sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

async function sendPromptAndWaitForResponse(promptText) {
    if (!sessionExists()) {
        createSession();
    }

    const wrappedPrompt = `Output your response between these exact markers:
${RESPONSE_MARKER_START}
[your response]
${RESPONSE_MARKER_END}

${promptText}`;

    const paneBeforeSend = capturePane();
    
    sendKeys(wrappedPrompt);
    sendEnter();

    const startTime = Date.now();
    let response = null;
    let lastEndIdx = paneBeforeSend.lastIndexOf(RESPONSE_MARKER_END);

    while ((Date.now() - startTime) < MAX_WAIT_MS) {
        await sleep(POLL_INTERVAL_MS);

        const paneContent = capturePane();

        const startIdx = paneContent.lastIndexOf(RESPONSE_MARKER_START);
        const endIdx = paneContent.lastIndexOf(RESPONSE_MARKER_END);

        if (startIdx !== -1 && endIdx !== -1 && endIdx > startIdx && endIdx > lastEndIdx) {
            response = paneContent
                .substring(startIdx + RESPONSE_MARKER_START.length, endIdx)
                .trim();
            break;
        }
    }

    if (!response) {
        throw new Error('Timeout waiting for Haiku response');
    }

    return response;
}

(async () => {
    try {
        const result = await sendPromptAndWaitForResponse(prompt);
        parentPort.postMessage({ success: true, result, sessionId: TMUX_SESSION_NAME });
    } catch (error) {
        parentPort.postMessage({ success: false, error: error.message });
    }
})();
