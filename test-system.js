const chokidar = require('chokidar');
const fs = require('fs');
const path = require('path');

const EXPECTED_MESSAGE = 'Successful handshake';
const logsDir = 'private/logs';
const testDir = 'private/test';
const sessionStates = new Map();

function appendTestResult(sessionNumber, text) {
    const testFile = path.join(testDir, `${sessionNumber}.txt`);
    fs.appendFileSync(testFile, text);
}

process.on('uncaughtException', (error) => {
    console.error(`💥 FATAL: Uncaught exception! ${error}\n❌ Test system crashed - this should NEVER happen!`);
    process.exit(1);
});

process.on('unhandledRejection', (reason, promise) => {
    console.error(`💥 FATAL: Unhandled promise rejection! Reason: ${reason}\n❌ Test system crashed - promises must be handled!`);
    process.exit(1);
});

console.log('Test system starting...');

if (!fs.existsSync(logsDir)) {
    fs.mkdirSync(logsDir, { recursive: true });
    console.log('Created logs directory');
}

if (!fs.existsSync(testDir)) {
    fs.mkdirSync(testDir, { recursive: true });
    console.log('Created test directory');
}

const logFiles = fs.readdirSync(logsDir).filter(f => f.endsWith('.json')).length;
const testFiles = fs.readdirSync(testDir).filter(f => f.endsWith('.txt')).length;

if (logFiles !== testFiles) {
    console.error(`❌ File count mismatch! Logs: ${logFiles}, Tests: ${testFiles}`);
    process.exit(1);
}

function isError(logData) {
    return 'error' in logData.type;
}

function runTestsForSession(sessionNumber) {
    const sessionFile = path.join(logsDir, `${sessionNumber}.json`);
    const state = sessionStates.get(sessionNumber);

    const content = fs.readFileSync(sessionFile, 'utf8');
    const lines = content.split('\n').filter(line => line.trim());

    const startIndex = state.lastProcessedIndex + 1;

    for (let i = startIndex; i < lines.length; i++) {
        const line = lines[i];
        state.lastProcessedIndex = i;

        const logData = JSON.parse(line);

        if (isError(logData) && !state.errorDetected) {
            state.errorDetected = true;
            state.errorDetails.push({
                file: logData.fileName,
                function: logData.functionName,
                message: logData.message
            });
        }

        if (logData.message.includes(EXPECTED_MESSAGE)) {
            state.handshakePassed = true;
        }
    }

    updateTestState(sessionNumber, state);
}

function updateTestState(sessionNumber, state) {
    const currentState = JSON.stringify({
        handshake: state.handshakePassed,
        hasErrors: state.errorDetected
    });

    if (currentState !== state.lastTestState) {
        state.lastTestState = currentState;
        writeStateChange(sessionNumber, state);
    }
}

function writeStateChange(sessionNumber, state) {
    const testStatus = `T1:${state.handshakePassed ? '✅' : '❌'} Err:${state.errorDetected ? `❌(${state.errorDetails.length})` : '✅'}`;
    const currentlyPassing = state.handshakePassed && !state.errorDetected;

    if (currentlyPassing && !state.allTestsPassed) {
        state.allTestsPassed = true;
        appendTestResult(sessionNumber, `\n✅ ALL TESTS PASSED! ${testStatus}\n`);
        appendTestResult(sessionNumber, `Test completed successfully at ${new Date().toLocaleString('en-GB')}\n`);
    } else if (state.errorDetected && state.allTestsPassed) {
        state.allTestsPassed = false;
        const errorSummary = state.errorDetails.map(e => `${e.file}:${e.function}:${e.message}`).join('; ');
        appendTestResult(sessionNumber, `❌ LATE ERROR! ${testStatus} | ${errorSummary}\n`);
    } else if (state.errorDetected && !state.allTestsPassed) {
        const errorSummary = state.errorDetails.map(e => `${e.file}:${e.function}:${e.message}`).join('; ');
        appendTestResult(sessionNumber, `❌ FAILED! ${testStatus} | ${errorSummary}\n`);
    } else if (!currentlyPassing) {
        appendTestResult(sessionNumber, `⏳ Waiting... ${testStatus}\n`);
    }
}

const watcher = chokidar.watch(logsDir, {
    persistent: true,
    ignoreInitial: true
});

watcher.on('add', (filePath) => {
    const filename = path.basename(filePath);
    if (!filename.endsWith('.json')) return;

    const sessionNumber = parseInt(filename.replace('.json', ''));
    const expectedNumber = fs.readdirSync(testDir).filter(f => f.endsWith('.txt')).length + 1;

    if (sessionNumber !== expectedNumber) {
        console.error(`❌ Session number mismatch! Got ${sessionNumber}, expected ${expectedNumber}`);
        process.exit(1);
    }

    const testFile = path.join(testDir, `${sessionNumber}.txt`);
    fs.writeFileSync(testFile, `🚀 Test Started at ${new Date().toLocaleString('en-GB')}\nRequirements:\n1) "Successful handshake"\n2) NO errors\n\n`);

    sessionStates.set(sessionNumber, {
        handshakePassed: false,
        errorDetected: false,
        errorDetails: [],
        lastTestState: null,
        allTestsPassed: false,
        lastProcessedIndex: -1
    });

    const sessionWatcher = chokidar.watch(filePath, {
        persistent: true,
        ignoreInitial: false
    });

    sessionWatcher.on('add', () => {
        setTimeout(() => runTestsForSession(sessionNumber), 100);
    });
});

watcher.on('error', error => {
    console.error(`💥 FATAL: Directory watcher crashed: ${error.message}\n❌ This should never happen - exiting immediately!`);
    process.exit(1);
});

console.log('Watching for new sessions in:', logsDir);