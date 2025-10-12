const chokidar = require('chokidar');
const fs = require('fs');
const path = require('path');
const os = require('os');

const EXPECTED_MESSAGE_1 = 'Successful handshake';
const EXPECTED_MESSAGE_2 = 'WebSocket connection established';
const EXPECTED_MESSAGE_3 = 'Voice activity detection started';
const EXPECTED_MESSAGE_4 = 'Voice activity detection stopped';
const EXPECTED_MESSAGE_5 = 'Prompt successfully injected into terminal';
const EXPECTED_MESSAGE_6 = 'Started playing response';
const EXPECTED_MESSAGE_7 = 'Stopped playing response';
const logsDir = 'private/logs';
const testDir = 'private/test';
const sessionStates = new Map();

// Get device information
const deviceInfo = `${os.hostname()}/${os.platform()}/${os.arch()}`;
let systemLogFile = null;

// Initialize system log file
function initSystemLogFile() {
    if (!fs.existsSync(testDir)) {
        fs.mkdirSync(testDir, { recursive: true });
    }
    systemLogFile = path.join(testDir, 'system.log');
}

// Single unified log function - ALWAYS writes to console AND file
function log(message, options = {}) {
    const { sessionNumber, isError = false } = options;
    const timestamp = new Date().toLocaleString('en-GB');
    const prefix = isError ? '❌ ERROR: ' : '';
    const formattedMessage = `[${timestamp}] [${deviceInfo}] ${prefix}${message}`;

    // ALWAYS write to console
    if (isError) {
        console.error(formattedMessage);
    } else {
        console.log(formattedMessage);
    }

    // Determine which file to write to
    let targetFile;
    if (sessionNumber) {
        targetFile = path.join(testDir, `${sessionNumber}.txt`);
    } else {
        // System messages go to system.log
        if (!systemLogFile) {
            initSystemLogFile();
        }
        targetFile = systemLogFile;
    }

    // ALWAYS write to file
    try {
        fs.appendFileSync(targetFile, `${formattedMessage}\n`);

        // Verify the file exists and was written successfully
        if (!fs.existsSync(targetFile)) {
            console.error(`💥 FATAL: Log file ${targetFile} does not exist after write!`);
            process.exit(1);
        }

        // Verify file size increased (basic write verification)
        const stats = fs.statSync(targetFile);
        if (stats.size === 0) {
            console.error(`💥 FATAL: Log file ${targetFile} is empty after write!`);
            process.exit(1);
        }
    } catch (err) {
        console.error(`💥 FATAL: Failed to write to log file ${targetFile}: ${err.message}`);
        process.exit(1);
    }
}

process.on('uncaughtException', (error) => {
    log(`💥 FATAL: Uncaught exception! ${error}\n❌ Test system crashed - this should NEVER happen!`, { isError: true });
    process.exit(1);
});

process.on('unhandledRejection', (reason, promise) => {
    log(`💥 FATAL: Unhandled promise rejection! Reason: ${reason}\n❌ Test system crashed - promises must be handled!`, { isError: true });
    process.exit(1);
});

log('Test system starting...');

if (!fs.existsSync(logsDir)) {
    fs.mkdirSync(logsDir, { recursive: true });
    log('Created logs directory');
}

if (!fs.existsSync(testDir)) {
    fs.mkdirSync(testDir, { recursive: true });
    log('Created test directory');
}

const logFiles = fs.readdirSync(logsDir).filter(f => f.endsWith('.json')).length;
const testFiles = fs.readdirSync(testDir).filter(f => f.endsWith('.txt')).length;

if (logFiles !== testFiles) {
    log(`💥 FATAL: File count mismatch! Logs: ${logFiles}, Tests: ${testFiles}`, { isError: true });
    process.exit(1);
}

const watcher = chokidar.watch(logsDir, {
    persistent: true,
    ignoreInitial: true
});

watcher.on('add', (filePath) => {
    const filename = path.basename(filePath);
    log(`📁 New file detected: ${filename}`);
    if (!filename.endsWith('.json')) return;

    const sessionNumber = parseInt(filename.replace('.json', ''));
    const expectedNumber = fs.readdirSync(testDir).filter(f => f.endsWith('.txt')).length + 1;

    if (sessionNumber !== expectedNumber) {
        log(`💥 FATAL: Session number mismatch! Got ${sessionNumber}, expected ${expectedNumber}`, { isError: true });
        process.exit(1);
    }

    const testFile = path.join(testDir, `${sessionNumber}.txt`);
    fs.writeFileSync(testFile, `🚀 Test Started at ${new Date().toLocaleString('en-GB')}\nRequirements:\n1) "Successful handshake"\n2) "WebSocket connection established"\n3) "Voice activity detection started"\n4) "Voice activity detection stopped"\n5) "Prompt successfully injected into terminal"\n6) "Started playing response"\n7) "Stopped playing response"\n8) NO errors\n\n`);

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
        setTimeout(() => {
            runTestsForSession(sessionNumber);
        }, 100);
    });
});

watcher.on('error', error => {
    log(`💥 FATAL: Directory watcher crashed: ${error.message}\n❌ This should never happen - exiting immediately!`, { isError: true });
    process.exit(1);
});

log('Watching for new sessions in:', logsDir);

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
            log(`T1: "Successful handshake" ✅`, { sessionNumber });
        }

        if (isWebRtcConnectedMessage(logData)) {
            state.webRtcConnected = true;
            log(`T2: "WebSocket connection established" ✅`, { sessionNumber });
        }

        if (isVadStartedMessage(logData)) {
            state.vadStarted = true;
            log(`T3: "Voice activity detection started" ✅`, { sessionNumber });
        }

        if (isVadStoppedMessage(logData)) {
            state.vadStopped = true;
            log(`T4: "Voice activity detection stopped" ✅`, { sessionNumber });
        }

        if (isPromptInjectedMessage(logData)) {
            state.promptInjected = true;
            log(`T5: "Prompt successfully injected into terminal" ✅`, { sessionNumber });
        }

        if (isPlayingStartedMessage(logData)) {
            state.playingStarted = true;
            log(`T6: "Started playing response" ✅`, { sessionNumber });
        }

        if (isPlayingStoppedMessage(logData)) {
            state.playingStopped = true;
            log(`T7: "Stopped playing response" ✅`, { sessionNumber });
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
    return `T1:${state.handshakePassed ? '✅' : '❌'} T2:${state.webRtcConnected ? '✅' : '❌'} T3:${state.vadStarted ? '✅' : '❌'} T4:${state.vadStopped ? '✅' : '❌'} T5:${state.promptInjected ? '✅' : '❌'} T6:${state.playingStarted ? '✅' : '❌'} T7:${state.playingStopped ? '✅' : '❌'} Err:${state.errorDetected ? `❌(${state.errorDetails.length})` : '✅'}`;
}

function testsJustPassed(state) {
    return allRequirementsMet(state) && !state.allTestsPassed;
}

function allRequirementsMet(state) {
    return state.handshakePassed && state.webRtcConnected && state.vadStarted && state.vadStopped && state.playingStarted && state.playingStopped && state.promptInjected && !state.errorDetected;
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
    log(`\n✅ ALL TESTS PASSED! ${testStatus}`, { sessionNumber });
    log(`T1: "Successful handshake" ✅`, { sessionNumber });
    log(`T2: "WebSocket connection established" ✅`, { sessionNumber });
    log(`T3: "Voice activity detection started" ✅`, { sessionNumber });
    log(`T4: "Voice activity detection stopped" ✅`, { sessionNumber });
    log(`T5: "Prompt successfully injected into terminal" ✅`, { sessionNumber });
    log(`T6: "Started playing response" ✅`, { sessionNumber });
    log(`T7: "Stopped playing response" ✅`, { sessionNumber });
    log(`T8: NO errors ✅`, { sessionNumber });
    log(`Test completed successfully at ${new Date().toLocaleString('en-GB')}`, { sessionNumber });
}

function handleLateError(sessionNumber, state, testStatus) {
    state.allTestsPassed = false;
    const errorSummary = formatErrorSummary(state);
    log(`LATE ERROR! ${testStatus} | ${errorSummary}`, { sessionNumber, isError: true });
}

function handleTestFailure(sessionNumber, state, testStatus) {
    const errorSummary = formatErrorSummary(state);
    log(`FAILED! ${testStatus} | ${errorSummary}`, { sessionNumber, isError: true });
}

function handleTestsPending(sessionNumber, testStatus) {
    log(`⏳ Waiting... ${testStatus}`, { sessionNumber });
}

function formatErrorSummary(state) {
    return state.errorDetails.map(e => `${e.file}:${e.function}:${e.message}`).join('; ');
}