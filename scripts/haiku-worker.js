const { parentPort, workerData } = require('worker_threads');
const { execSync } = require('child_process');
const fs = require('fs');

const { prompt, task } = workerData;

try {
    const inputFile = `/tmp/haiku-worker-${Date.now()}.txt`;
    const outputFile = `/tmp/haiku-worker-${Date.now()}-out.txt`;

    fs.writeFileSync(inputFile, prompt);

    execSync(`cat "${inputFile}" | claude --model haiku --print - > "${outputFile}" 2>&1`, {
        stdio: 'ignore',
        shell: '/bin/bash',
        timeout: 30000
    });

    const result = fs.readFileSync(outputFile, 'utf8').trim();

    fs.unlinkSync(inputFile);
    fs.unlinkSync(outputFile);

    parentPort.postMessage({ success: true, result });
} catch (error) {
    parentPort.postMessage({ success: false, error: error.message });
}
