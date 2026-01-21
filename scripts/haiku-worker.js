const { parentPort, workerData } = require('worker_threads');
const { execSync } = require('child_process');
const fs = require('fs');

const { prompt, task, sessionId } = workerData;

try {
    const timestamp = Date.now();
    const inputFile = `/tmp/haiku-worker-${timestamp}.txt`;
    const outputFile = `/tmp/haiku-worker-${timestamp}-out.txt`;

    fs.writeFileSync(inputFile, prompt);

    const sessionFlag = sessionId ? `--session-id ${sessionId}` : '';
    execSync(`cat "${inputFile}" | claude --model haiku --print --output-format json ${sessionFlag} - > "${outputFile}" 2>&1`, {
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

    parentPort.postMessage({ success: true, result, sessionId: returnedSessionId });
} catch (error) {
    parentPort.postMessage({ success: false, error: error.message });
}
