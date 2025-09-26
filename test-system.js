const chokidar = require('chokidar');
const fs = require('fs');
const path = require('path');

const EXPECTED_MESSAGE_1 = 'Successful handshake';
const EXPECTED_MESSAGE_2 = 'WebSocket connection established';
const EXPECTED_MESSAGE_3 = 'Voice activity detection started';
const EXPECTED_MESSAGE_4 = 'Voice activity detection stopped';
const EXPECTED_MESSAGE_5 = 'Started playing response';
const EXPECTED_MESSAGE_6 = 'Stopped playing response';
const logsDir = 'private/logs';
const testDir = 'private/test';
const sessionStates = new Map();

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

const watcher = chokidar.watch(logsDir, {
    persistent: true,
    ignoreInitial: true
});

watcher.on('add', (filePath) => {
    const filename = path.basename(filePath);
    console.log(`📁 New file detected: ${filename}`);
    if (!filename.endsWith('.json')) return;

    const sessionNumber = parseInt(filename.replace('.json', ''));
    const expectedNumber = fs.readdirSync(testDir).filter(f => f.endsWith('.txt')).length + 1;

    if (sessionNumber !== expectedNumber) {
        console.error(`❌ Session number mismatch! Got ${sessionNumber}, expected ${expectedNumber}`);
        process.exit(1);
    }

    const testFile = path.join(testDir, `${sessionNumber}.txt`);
    fs.writeFileSync(testFile, `🚀 Test Started at ${new Date().toLocaleString('en-GB')}\nRequirements:\n1) "Successful handshake"\n2) "WebSocket connection established"\n3) "Voice activity detection started"\n4) "Voice activity detection stopped"\n5) "Started playing response"\n6) "Stopped playing response"\n7) "Prompt successfully injected into terminal"\n8) NO errors\n\n`);

    sessionStates.set(sessionNumber, {
        handshakePassed: false,
        webRtcConnected: false,
        vadStarted: false,
        vadStopped: false,
        playingStarted: false,
        playingStopped: false,
        promptInjected: false,
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

    sessionWatcher.on('change', () => {
        console.log(`📂 SessionWatcher detected change for session ${sessionNumber}`);
        setTimeout(() => {
            console.log(`🧪 Running tests for session ${sessionNumber}...`);
            runTestsForSession(sessionNumber);
        }, 100);
    });
});

watcher.on('error', error => {
    console.error(`💥 FATAL: Directory watcher crashed: ${error.message}\n❌ This should never happen - exiting immediately!`);
    process.exit(1);
});

console.log('Watching for new sessions in:', logsDir);

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

        // Always record ALL errors, not just the first one
        if (isErrorLog(logData)) {
            recordError(state, logData);
        }

        if (isHandshakeMessage(logData)) {
            markHandshakeAsPassed(state);
        }

        if (isWebRtcConnectedMessage(logData)) {
            state.webRtcConnected = true;
        }

        if (isVadStartedMessage(logData)) {
            state.vadStarted = true;
        }

        if (isVadStoppedMessage(logData)) {
            state.vadStopped = true;
        }

        if (isPlayingStartedMessage(logData)) {
            state.playingStarted = true;
        }

        if (isPlayingStoppedMessage(logData)) {
            state.playingStopped = true;
        }

        if (isPromptInjectedMessage(logData)) {
            state.promptInjected = true;
        }
    }

    updateTestState(sessionNumber, state);
}

function isErrorLog(logData) {
    return 'error' in logData.type;
}


function recordError(state, logData) {
    // Mark that we've seen an error
    if (!state.errorDetected) {
        state.errorDetected = true;
    }

    // Always add to error details array
    state.errorDetails.push({
        file: logData.fileName,
        function: logData.functionName,
        message: logData.message
    });
}

function isHandshakeMessage(logData) {
    return logData.message.includes(EXPECTED_MESSAGE_1);
}

function markHandshakeAsPassed(state) {
    state.handshakePassed = true;
}

function isWebRtcConnectedMessage(logData) {
    return logData.message.includes(EXPECTED_MESSAGE_2);
}

function isVadStartedMessage(logData) {
    return logData.message.includes(EXPECTED_MESSAGE_3);
}

function isVadStoppedMessage(logData) {
    return logData.message.includes(EXPECTED_MESSAGE_4);
}

function isPlayingStartedMessage(logData) {
    return logData.message.includes(EXPECTED_MESSAGE_5);
}

function isPlayingStoppedMessage(logData) {
    return logData.message.includes(EXPECTED_MESSAGE_6);
}

function isPromptInjectedMessage(logData) {
    return logData.message && logData.message.includes('Prompt successfully injected into terminal');
}

function updateTestState(sessionNumber, state) {
    const currentState = JSON.stringify({
        handshake: state.handshakePassed,
        webRtc: state.webRtcConnected,
        vadStart: state.vadStarted,
        vadStop: state.vadStopped,
        playStart: state.playingStarted,
        playStop: state.playingStopped,
        promptInject: state.promptInjected,
        hasErrors: state.errorDetected,
        errorCount: state.errorDetails.length  // Track error count changes
    });

    if (stateHasChanged(currentState, state)) {
        state.lastTestState = currentState;
        writeStateChange(sessionNumber, state);
    }
}

function stateHasChanged(currentState, state) {
    return currentState !== state.lastTestState;
}

function writeStateChange(sessionNumber, state) {
    const testStatus = formatTestStatus(state);

    if (testsJustPassed(state)) {
        handleTestsPassed(sessionNumber, state, testStatus);
    } else if (errorOccurredAfterPassing(state)) {
        handleLateError(sessionNumber, state, testStatus);
    } else if (errorOccurredBeforePassing(state)) {
        handleTestFailure(sessionNumber, state, testStatus);
    } else if (testsStillPending(state)) {
        handleTestsPending(sessionNumber, testStatus);
    }
}

function formatTestStatus(state) {
    return `T1:${state.handshakePassed ? '✅' : '❌'} T2:${state.webRtcConnected ? '✅' : '❌'} T3:${state.vadStarted ? '✅' : '❌'} T4:${state.vadStopped ? '✅' : '❌'} T5:${state.playingStarted ? '✅' : '❌'} T6:${state.playingStopped ? '✅' : '❌'} Err:${state.errorDetected ? `❌(${state.errorDetails.length})` : '✅'}`;
}

function testsJustPassed(state) {
    return allRequirementsMet(state) && !state.allTestsPassed;
}

function allRequirementsMet(state) {
    return state.handshakePassed && state.webRtcConnected && state.vadStarted && state.vadStopped && state.playingStarted && state.playingStopped && !state.errorDetected;
}

function errorOccurredAfterPassing(state) {
    return state.errorDetected && state.allTestsPassed;
}

function errorOccurredBeforePassing(state) {
    return state.errorDetected && !state.allTestsPassed;
}

function testsStillPending(state) {
    return !allRequirementsMet(state);
}

function handleTestsPassed(sessionNumber, state, testStatus) {
    state.allTestsPassed = true;
    appendTestResult(sessionNumber, `\n✅ ALL TESTS PASSED! ${testStatus}\n`);
    appendTestResult(sessionNumber, `Test completed successfully at ${new Date().toLocaleString('en-GB')}\n`);
}

function handleLateError(sessionNumber, state, testStatus) {
    state.allTestsPassed = false;
    const errorSummary = formatErrorSummary(state);
    appendTestResult(sessionNumber, `❌ LATE ERROR! ${testStatus} | ${errorSummary}\n`);
}

function handleTestFailure(sessionNumber, state, testStatus) {
    const errorSummary = formatErrorSummary(state);
    appendTestResult(sessionNumber, `❌ FAILED! ${testStatus} | ${errorSummary}\n`);
}

function handleTestsPending(sessionNumber, testStatus) {
    appendTestResult(sessionNumber, `⏳ Waiting... ${testStatus}\n`);
}

function formatErrorSummary(state) {
    return state.errorDetails.map(e => `${e.file}:${e.function}:${e.message}`).join('; ');
}

function appendTestResult(sessionNumber, text) {
    const testFile = path.join(testDir, `${sessionNumber}.txt`);
    fs.appendFileSync(testFile, text);
}