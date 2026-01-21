const { exec, spawn } = require("child_process");
const util = require("util");
const fs = require("fs");

const execAsync = util.promisify(exec);

const TMUX_SESSION_NAME = "haiku-conversation";
const RESPONSE_MARKER_START = "___HAIKU_RESPONSE_START___";
const RESPONSE_MARKER_END = "___HAIKU_RESPONSE_END___";
const OUTPUT_FILE = "/tmp/haiku-tmux-output.txt";
const POLL_INTERVAL_MS = 100;
const MAX_WAIT_MS = 30000;

function log(message, functionName = "unknown") {
    console.log(`[haiku-tmux] ${functionName}: ${message}`);
}

function error(message, functionName = "unknown") {
    console.error(`[haiku-tmux] ERROR ${functionName}: ${message}`);
}

async function invariantTmuxSession() {
    const exists = await sessionExists();
    if (!exists) {
        error(`INV: tmux session "${TMUX_SESSION_NAME}" does not exist`, "invariantTmuxSession");
        throw new Error(`INV: tmux session "${TMUX_SESSION_NAME}" does not exist`);
    }
    log(`INV: tmux session OK - exists=true`, "invariantTmuxSession");
}

async function preconditionSendPrompt(prompt) {
    if (!prompt) {
        error("PRE: prompt is null/undefined", "preconditionSendPrompt");
        throw new Error("PRE: sendPrompt prompt is null");
    }
    if (prompt.trim() === "") {
        error("PRE: prompt is empty string", "preconditionSendPrompt");
        throw new Error("PRE: sendPrompt prompt is empty");
    }
    if (prompt.length > 50000) {
        error(`PRE: prompt too long: ${prompt.length}`, "preconditionSendPrompt");
        throw new Error("PRE: sendPrompt prompt too long");
    }
    await invariantTmuxSession();
    log(`PRE: sendPrompt OK - promptLen=${prompt.length}`, "preconditionSendPrompt");
}

async function postconditionSendPrompt(response) {
    if (!response) {
        error("POST: response is null/undefined", "postconditionSendPrompt");
        throw new Error("POST: sendPrompt returned null response");
    }
    if (response.trim() === "") {
        error("POST: response is empty string", "postconditionSendPrompt");
        throw new Error("POST: sendPrompt returned empty response");
    }
    await invariantTmuxSession();
    log(`POST: sendPrompt OK - responseLen=${response.length}`, "postconditionSendPrompt");
}

function preconditionCreateSession() {
    log("PRE: createSession starting", "preconditionCreateSession");
}

async function postconditionCreateSession() {
    const exists = await sessionExists();
    if (!exists) {
        error("POST: session was not created", "postconditionCreateSession");
        throw new Error("POST: createSession failed to create session");
    }
    log("POST: createSession OK - session exists", "postconditionCreateSession");
}

async function preconditionSendKeys(text) {
    if (!text) {
        error("PRE: text is null/undefined", "preconditionSendKeys");
        throw new Error("PRE: sendKeys text is null");
    }
    await invariantTmuxSession();
    log(`PRE: sendKeys OK - textLen=${text.length}`, "preconditionSendKeys");
}

async function postconditionSendKeys() {
    await invariantTmuxSession();
    log("POST: sendKeys OK - keys sent", "postconditionSendKeys");
}

async function preconditionCapturePane() {
    await invariantTmuxSession();
    log("PRE: capturePane OK", "preconditionCapturePane");
}

function postconditionCapturePane(output) {
    if (output === null || output === undefined) {
        error("POST: capturePane returned null", "postconditionCapturePane");
    }
    log(`POST: capturePane OK - outputLen=${output ? output.length : 0}`, "postconditionCapturePane");
}

async function sessionExists() {
    try {
        await execAsync(`tmux has-session -t ${TMUX_SESSION_NAME} 2>/dev/null`);
        log("sessionExists: true", "sessionExists");
        return true;
    } catch {
        log("sessionExists: false", "sessionExists");
        return false;
    }
}

async function createSession() {
    preconditionCreateSession();

    if (await sessionExists()) {
        log("Session already exists, skipping creation", "createSession");
        return;
    }

    log("Creating new tmux session...", "createSession");
    await execAsync(`tmux new-session -d -s ${TMUX_SESSION_NAME} -x 200 -y 50`);
    log("Tmux session created", "createSession");

    log("Starting claude CLI in session...", "createSession");
    await execAsync(`tmux send-keys -t ${TMUX_SESSION_NAME} "claude --model haiku --verbose" Enter`);

    let ready = false;
    const startTime = Date.now();
    let pollCount = 0;
    while (!ready && (Date.now() - startTime) < 10000) {
        pollCount++;
        const output = await capturePane();
        if (output.includes(">") || output.includes("Claude")) {
            ready = true;
            log(`Claude CLI ready after ${pollCount} polls`, "createSession");
        } else {
            await new Promise(resolve => setTimeout(resolve, 500));
        }
    }

    if (!ready) {
        error(`Claude CLI did not start within timeout after ${pollCount} polls`, "createSession");
        throw new Error("Claude CLI did not start within timeout");
    }

    await postconditionCreateSession();
}

async function capturePane() {
    try {
        await preconditionCapturePane();
        const { stdout } = await execAsync(`tmux capture-pane -t ${TMUX_SESSION_NAME} -p -S -1000`);
        postconditionCapturePane(stdout);
        return stdout;
    } catch (err) {
        error(`capturePane failed: ${err.message}`, "capturePane");
        return "";
    }
}

async function sendKeys(text) {
    await preconditionSendKeys(text);

    const escaped = text
        .replace(/\\/g, "\\\\")
        .replace(/"/g, "\\\"")
        .replace(/\$/g, "\\$")
        .replace(/\`/g, "\\\`");

    await execAsync(`tmux send-keys -t ${TMUX_SESSION_NAME} "${escaped}"`);

    await postconditionSendKeys();
}

async function sendEnter() {
    await invariantTmuxSession();
    log("Sending Enter key", "sendEnter");
    await execAsync(`tmux send-keys -t ${TMUX_SESSION_NAME} Enter`);
    log("Enter key sent", "sendEnter");
}

async function sendPromptAndWaitForResponse(prompt) {
    await preconditionSendPrompt(prompt);
    log(`Starting prompt processing - promptLen=${prompt.length}`, "sendPromptAndWaitForResponse");

    const wrappedPrompt = `Please wrap your ENTIRE response between these exact markers (include them in your output):
${RESPONSE_MARKER_START}
<your response here>
${RESPONSE_MARKER_END}

Now process this:
${prompt}`;

    log(`Wrapped prompt created - wrappedLen=${wrappedPrompt.length}`, "sendPromptAndWaitForResponse");

    const paneBefore = await capturePane();
    const linesBefore = paneBefore.split("\n").length;
    log(`Pane state before: ${linesBefore} lines`, "sendPromptAndWaitForResponse");

    await sendKeys(wrappedPrompt);
    await sendEnter();
    log("Prompt sent, waiting for response...", "sendPromptAndWaitForResponse");

    const startTime = Date.now();
    let response = null;
    let pollCount = 0;

    while ((Date.now() - startTime) < MAX_WAIT_MS) {
        await new Promise(resolve => setTimeout(resolve, POLL_INTERVAL_MS));
        pollCount++;

        const paneContent = await capturePane();

        const startIdx = paneContent.lastIndexOf(RESPONSE_MARKER_START);
        const endIdx = paneContent.lastIndexOf(RESPONSE_MARKER_END);

        if (startIdx !== -1 && endIdx !== -1 && endIdx > startIdx) {
            response = paneContent
                .substring(startIdx + RESPONSE_MARKER_START.length, endIdx)
                .trim();
            log(`Response found after ${pollCount} polls, ${Date.now() - startTime}ms`, "sendPromptAndWaitForResponse");
            break;
        }

        if (pollCount % 50 === 0) {
            log(`Still waiting... ${pollCount} polls, ${Date.now() - startTime}ms`, "sendPromptAndWaitForResponse");
        }
    }

    if (!response) {
        error(`Timeout after ${pollCount} polls, ${MAX_WAIT_MS}ms`, "sendPromptAndWaitForResponse");
        throw new Error("Timeout waiting for Haiku response");
    }

    await postconditionSendPrompt(response);
    log(`Response complete - responseLen=${response.length}`, "sendPromptAndWaitForResponse");
    return response;
}

async function killSession() {
    log("killSession called", "killSession");
    if (await sessionExists()) {
        await execAsync(`tmux kill-session -t ${TMUX_SESSION_NAME}`);
        log("Session killed", "killSession");
    } else {
        log("No session to kill", "killSession");
    }
}

async function ensureSession() {
    log("ensureSession called", "ensureSession");
    if (!(await sessionExists())) {
        log("Session does not exist, creating...", "ensureSession");
        await createSession();
    } else {
        log("Session already exists", "ensureSession");
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
