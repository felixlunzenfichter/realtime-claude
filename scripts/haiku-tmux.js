const { exec } = require("child_process");
const util = require("util");
const fs = require("fs");

const execAsync = util.promisify(exec);

const TMUX_SESSION_NAME = "haiku-conversation";
const POLL_INTERVAL_MS = 300;
const MAX_WAIT_MS = 60000;

function log(message, functionName) {
    console.log("[haiku-tmux] " + functionName + ": " + message);
}

function error(message, functionName) {
    console.error("[haiku-tmux] ERROR " + functionName + ": " + message);
}

async function invariantTmuxSession() {
    var exists = await sessionExists();
    if (!exists) {
        error("INV: tmux session does not exist", "invariantTmuxSession");
        throw new Error("INV: tmux session does not exist");
    }
}

async function preconditionSendPrompt(prompt) {
    if (!prompt) {
        error("PRE: prompt is null/undefined", "preconditionSendPrompt");
        throw new Error("PRE: prompt is null");
    }
    if (prompt.trim() === "") {
        error("PRE: prompt is empty string", "preconditionSendPrompt");
        throw new Error("PRE: prompt is empty");
    }
    if (prompt.length > 50000) {
        error("PRE: prompt too long: " + prompt.length, "preconditionSendPrompt");
        throw new Error("PRE: prompt too long");
    }
    await invariantTmuxSession();
    log("PRE: sendPrompt OK - promptLen=" + prompt.length, "preconditionSendPrompt");
}

async function postconditionSendPrompt(response) {
    if (!response) {
        error("POST: response is null/undefined", "postconditionSendPrompt");
        throw new Error("POST: response is null");
    }
    if (response.trim() === "") {
        error("POST: response is empty string", "postconditionSendPrompt");
        throw new Error("POST: response is empty");
    }
    await invariantTmuxSession();
    log("POST: sendPrompt OK - responseLen=" + response.length, "postconditionSendPrompt");
}

async function sessionExists() {
    try {
        await execAsync("tmux has-session -t " + TMUX_SESSION_NAME + " 2>/dev/null");
        return true;
    } catch (e) {
        return false;
    }
}

async function createSession() {
    if (await sessionExists()) {
        log("Session already exists", "createSession");
        return;
    }

    log("Creating new tmux session", "createSession");
    await execAsync("tmux new-session -d -s " + TMUX_SESSION_NAME + " -x 200 -y 50");

    await execAsync("tmux send-keys -t " + TMUX_SESSION_NAME + " 'cd /tmp && claude --model haiku --dangerously-skip-permissions' Enter");

    var ready = false;
    var startTime = Date.now();
    while (!ready && (Date.now() - startTime) < 25000) {
        var output = await capturePane();
        if (output.includes("bypass") || output.includes("shortcuts")) {
            ready = true;
            log("Claude CLI ready", "createSession");
        } else {
            await new Promise(function(resolve) { setTimeout(resolve, 500); });
        }
    }

    if (!ready) {
        error("Claude CLI did not start within timeout", "createSession");
        throw new Error("Claude CLI did not start within timeout");
    }

    await new Promise(function(resolve) { setTimeout(resolve, 1000); });
}

async function capturePane() {
    try {
        var result = await execAsync("tmux capture-pane -t " + TMUX_SESSION_NAME + " -p -S -500");
        return result.stdout;
    } catch (e) {
        return "";
    }
}

async function sendKeys(text) {
    var tempFile = "/tmp/haiku-prompt-" + process.pid + ".txt";
    fs.writeFileSync(tempFile, text);

    await execAsync("tmux load-buffer " + tempFile);
    await execAsync("tmux paste-buffer -t " + TMUX_SESSION_NAME);

    try { fs.unlinkSync(tempFile); } catch (e) {}
}

async function sendEnter() {
    await execAsync("tmux send-keys -t " + TMUX_SESSION_NAME + " Enter");
}

function isThinkingIndicator(text) {
    var thinkingPatterns = [
        "Doodling", "Levitating", "Synthesizing", "Pondering",
        "Thinking", "thinking", "interrupt", "esc to"
    ];
    for (var i = 0; i < thinkingPatterns.length; i++) {
        if (text.includes(thinkingPatterns[i])) return true;
    }
    return false;
}

function extractResponseFromPane(paneContent, promptText) {
    var lines = paneContent.split("\n");
    var promptStart = promptText.substring(0, 40).trim();

    var promptLineIdx = -1;
    for (var i = lines.length - 1; i >= 0; i--) {
        if (lines[i].includes(promptStart)) {
            promptLineIdx = i;
            break;
        }
    }

    if (promptLineIdx === -1) {
        return null;
    }

    var responseLines = [];
    var inResponse = false;

    for (var i = promptLineIdx + 1; i < lines.length; i++) {
        var line = lines[i];
        var trimmedLine = line.trim();

        if (trimmedLine.length === 0) continue;

        if (trimmedLine.includes("\u276F") && !inResponse) continue;

        if (trimmedLine.startsWith("\u23FA")) {
            inResponse = true;
            var responsePart = trimmedLine.replace(/^\u23FA\s*/, "").trim();
            if (responsePart.length > 0 && !isThinkingIndicator(responsePart)) {
                responseLines.push(responsePart);
            }
            continue;
        }

        if (inResponse) {
            if (trimmedLine.startsWith("\u276F") || trimmedLine.includes("send") || trimmedLine.includes("bypass")) {
                break;
            }
            if (!isThinkingIndicator(trimmedLine) && !trimmedLine.startsWith("\u2500")) {
                responseLines.push(trimmedLine);
            }
        }
    }

    var response = responseLines.join("\n").trim();

    if (response.length > 10 && !isThinkingIndicator(response)) {
        return response;
    }

    return null;
}

async function sendPromptAndWaitForResponse(prompt) {
    await preconditionSendPrompt(prompt);
    log("Starting - promptLen=" + prompt.length, "sendPromptAndWaitForResponse");

    await sendKeys(prompt);
    await sendEnter();
    log("Prompt sent, waiting for response...", "sendPromptAndWaitForResponse");

    var startTime = Date.now();
    var response = null;
    var lastPaneLength = 0;
    var stableCount = 0;

    while ((Date.now() - startTime) < MAX_WAIT_MS) {
        await new Promise(function(resolve) { setTimeout(resolve, POLL_INTERVAL_MS); });

        var paneContent = await capturePane();

        response = extractResponseFromPane(paneContent, prompt);

        if (response && response.length > 20) {
            if (paneContent.length === lastPaneLength) {
                stableCount++;
                if (stableCount >= 3) {
                    log("Response stable (" + response.length + " chars)", "sendPromptAndWaitForResponse");
                    break;
                }
            } else {
                stableCount = 0;
                lastPaneLength = paneContent.length;
            }
        } else {
            stableCount = 0;
            lastPaneLength = paneContent.length;
        }
    }

    if (!response || response.length < 10) {
        error("No valid response found", "sendPromptAndWaitForResponse");
        throw new Error("Timeout waiting for response");
    }

    await postconditionSendPrompt(response);
    return response;
}

async function killSession() {
    if (await sessionExists()) {
        await execAsync("tmux kill-session -t " + TMUX_SESSION_NAME);
        log("Session killed", "killSession");
    }
}

async function ensureSession() {
    if (!(await sessionExists())) {
        await createSession();
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
