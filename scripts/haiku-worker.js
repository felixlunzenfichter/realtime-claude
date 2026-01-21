const { parentPort, workerData } = require("worker_threads");
const { spawn } = require("child_process");

const { prompt, task } = workerData;

function log(message, functionName) {
    console.log("[haiku-worker] " + functionName + ": " + message);
}

function error(message, functionName) {
    console.error("[haiku-worker] ERROR " + functionName + ": " + message);
}

function preconditionCallHaiku(prompt) {
    if (!prompt) {
        error("PRE: prompt is null/undefined", "preconditionCallHaiku");
        throw new Error("PRE: prompt is null");
    }
    if (prompt.trim() === "") {
        error("PRE: prompt is empty string", "preconditionCallHaiku");
        throw new Error("PRE: prompt is empty");
    }
    if (prompt.length > 50000) {
        error("PRE: prompt too long: " + prompt.length, "preconditionCallHaiku");
        throw new Error("PRE: prompt too long");
    }
    log("PRE: callHaiku OK - promptLen=" + prompt.length, "preconditionCallHaiku");
}

function postconditionCallHaiku(response) {
    if (!response) {
        error("POST: response is null/undefined", "postconditionCallHaiku");
        throw new Error("POST: response is null");
    }
    if (response.trim() === "") {
        error("POST: response is empty string", "postconditionCallHaiku");
        throw new Error("POST: response is empty");
    }
    log("POST: callHaiku OK - responseLen=" + response.length, "postconditionCallHaiku");
}

async function callHaiku(prompt) {
    preconditionCallHaiku(prompt);

    const response = await new Promise((resolve, reject) => {
        const child = spawn("claude", ["--model", "haiku", "--print"], {
            detached: true,
            stdio: ["pipe", "pipe", "pipe"]
        });

        let stdout = "";
        let stderr = "";

        child.stdout.on("data", data => stdout += data);
        child.stderr.on("data", data => stderr += data);

        child.stdin.write(prompt);
        child.stdin.end();

        child.on("close", code => {
            if (code === 0) {
                resolve(stdout.trim());
            } else {
                reject(new Error("Haiku failed (code " + code + "): " + stderr));
            }
        });

        child.on("error", err => {
            reject(new Error("Haiku spawn error: " + err.message));
        });

        child.unref();
    });

    postconditionCallHaiku(response);
    return response;
}

async function main() {
    try {
        log("Starting - task=" + task + ", promptLen=" + prompt.length, "main");
        const response = await callHaiku(prompt);

        parentPort.postMessage({
            success: true,
            result: response,
            sessionId: "one-shot"
        });
    } catch (err) {
        error(err.message, "main");
        parentPort.postMessage({
            success: false,
            error: err.message
        });
    }
}

main();
