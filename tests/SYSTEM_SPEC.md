# System Architecture: Before & After

---

## BEFORE (Old System)

```
┌─────────────────────────────────────────────────────────────┐
│                     iOS APP (POLLUTED)                       │
├─────────────────────────────────────────────────────────────┤
│  Logger.swift:                                               │
│    - TEST_DEFINITIONS array                                  │
│    - testsPassedSubject                                      │
│    - Test tracking logic                                     │
│    - Production + test code mixed                            │
│                                                              │
│  LogListView.swift:                                          │
│    - successfulTests counter                                 │
│    - totalTests counter                                      │
│    - Test result UI                                          │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
                    HUMAN IN THE LOOP
                            │
                    Deploy app
                    Open app manually
                    Speak into microphone
                    Watch for test results
                    Check if tests passed
```

**Problems:**
- Test code in production app
- Manual testing required
- Human must speak, watch, verify
- Slow, tedious, error-prone
- Can't run tests automatically

---

## AFTER (New System)

```
┌─────────────────────────────────────────────────────────────┐
│                      STORY.md                                │
│  Human-readable. Machine-executable.                         │
├─────────────────────────────────────────────────────────────┤
│  { "action": "Say Hello to A", "result": "A responded" }    │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                    MAC SERVER (BRAIN)                        │
├─────────────────────────────────────────────────────────────┤
│  Parser:                                                     │
│    "Say Hello to A" → mockWhisper("A", "Hello")             │
│                                                              │
│  Mocks:                                                      │
│    mockWhisper() - injects text as transcription            │
│    mockTTS() - receives audio, does nothing                  │
│                                                              │
│  Runner:                                                     │
│    Parse action → Execute → Wait for result → Next          │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                    iOS APP (CLEAN)                           │
├─────────────────────────────────────────────────────────────┤
│  Zero test code.                                             │
│  Just displays what Mac sends.                               │
│  --test flag only changes:                                   │
│    - Port: 9082 instead of 8082                             │
│    - TTS: mocked (silent)                                    │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                    CLAUDE (REAL)                             │
├─────────────────────────────────────────────────────────────┤
│  Real AI. Real responses. Real sub-agents.                   │
│  No mocking. The actual system under test.                   │
└─────────────────────────────────────────────────────────────┘
```

---

## What Changed

| Component | Before | After |
|-----------|--------|-------|
| iOS app | Test code mixed in | Zero test code |
| Test location | Logger.swift | mac-server.js |
| Test format | Hardcoded arrays | STORY.md (human-readable) |
| Execution | Manual | Automated |
| Audio | Real microphone | mockWhisper() |
| TTS | Real speakers | mockTTS() |
| Port | 8082 always | 8082 prod / 9082 test |

---

## The Idea (Why)

**Separation of concerns.**

- Production code = production code. Nothing else.
- Test code = test code. Lives in `tests/` directory.
- iOS app doesn't know it's being tested. It just runs.
- Mac server orchestrates everything.

**Human language as test specification.**

- Write what should happen in English
- Machine translates to function calls
- No programming required to write tests
- Tests are documentation

**Full automation.**

- No human in the loop
- Run tests before deploy
- Tests pass → merge → deploy
- Tests fail → fix in worktree → try again

---

## File Structure

```
WORKTREE (experiments)              PRODUCTION (clean)
────────────────────                ──────────────────
~/Documents/worktrees/test-branch/  ~/Documents/realtime-claude/
├── tests/                          (no tests/ folder)
│   ├── STORY.md
│   ├── SYSTEM_SPEC.md
│   └── TEST_ARCHITECTURE.md
├── scripts/mac-server.js           ├── scripts/mac-server.js
│   (port 9082, parser, mocks)      │   (port 8082, no test code)
└── RealtimeClaude/                 └── RealtimeClaude/
    └── (--test flag only)              └── (production)
```

---

## The Core Idea

A sentence IS a function call.

```
"Say Hello to A"  =  mockWhisper("A", "Hello")
```

Same thing. Two representations. One human, one machine.

### The Parser

Maps sentences to functions:

| Sentence | Function |
|----------|----------|
| `"Say Hello to A"` | `mockWhisper("A", "Hello")` |
| `"Say Goodbye to B"` | `mockWhisper("B", "Goodbye")` |
| `"Tell B to spawn a helper"` | `mockWhisper("B", "spawn a helper")` |

The whole sentence. Directly to a function.

---

## Current Bug (To Fix)

`storyLog()` wasn't adding to `storyLogs` array, so `waitForLog("A responded")` never matched.

**Fix needed in `scripts/mac-server.js`:**

```javascript
// 1. storyLog must add to storyLogs (DONE)
function storyLog(msg) {
    console.log(`[STORY] ${msg}`);
    storyLogs.push(msg);  // ← added
}

// 2. mockWhisper must log "{conversation} responded" (TODO)
function mockWhisper(conversation, text) {
    // ... existing code ...
    haikuPriorityQueue.add(2, async () => {
        const summary = ...;
        activeSocket.write(...);
        storyLog(`${conversation} responded`);  // ← add this
    });
}
```

---

## Run Test

```bash
# 1. Start test server
cd ~/Documents/worktrees/cleanup-ios-tests
node scripts/mac-server.js --test > /tmp/mac-server-test.log 2>&1 &

# 2. Deploy iOS app with --test
xcrun devicectl device process launch --device DEVICE_ID ch.felix.realtimeClaude -- --test

# 3. Watch results
tail -f /tmp/mac-server-test.log | grep STORY
```

### Success Criteria

```
[STORY] === STORY STARTED ===
[STORY] Step 1/4: Say Hello to A
[STORY] ✓ A responded
[STORY] Step 2/4: Say Hello to B
[STORY] ✓ B responded
...
[STORY] === STORY COMPLETED ===
```
