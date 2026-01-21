const { parentPort, workerData } = require('worker_threads');
const {
    TMUX_SESSION_NAME,
    ensureSession,
    sendPromptAndWaitForResponse
} = require('./haiku-tmux.js');

const { prompt, task } = workerData;

async function main() {
    try {
        ensureSession();

        const response = await sendPromptAndWaitForResponse(prompt);

        parentPort.postMessage({
            success: true,
            result: response,
            sessionId: TMUX_SESSION_NAME
        });
    } catch (error) {
        parentPort.postMessage({
            success: false,
            error: error.message
        });
    }
}

main();
