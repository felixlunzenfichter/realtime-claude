# CLAUDE.md

## System Information
- **Current Date: September 26, 2025**
- **iOS 26** (Release Date: September 15, 2025)
- **iPadOS 26** (Release Date: September 15, 2025)
- **macOS 26 Tahoe** (Release Date: September 15, 2025)
- **Xcode 18** (Release Date: September 2025)
- **OpenAI Realtime API Version**: gpt-realtime (GA since Aug 28, 2025)
- Note: Apple changed numbering to unify all OS versions at "26" for 2025-2026 season

## Core Principles

**100% dogfood. Everything crashes immediately.**

- Use `!` everywhere, never `if let` or `guard let`
- Use `try!` everywhere, never `do-catch`
- Any error = immediate crash = we see it in the debugger

Always debug mode, always direct install. This is our tool.

## TDD Development

Each task = 3 commits:
1. Write test (test file is located in: scripts/test-system.js)
2. Make test pass (minimal code only, ignore refactoring rules)
3. Refactor & clean up (apply refactoring rules)

### Implementation Rules (Step 2)
- Focus on making test pass quickly
- Comment heavily mentioning resources, documentation links, API references
- Include TODO comments for things to clean up in refactoring
- Document any assumptions or gotchas discovered
- Make heavy use of log() and error() functions (see Logger.swift for usage)
- Log all successes and especially catch ALL errors with error()

### Refactoring Rules (Step 3)
- Apply ONLY after test passes
- Function ordering: If function A uses function B, then B must be defined below A
- Function ordering: If function A is used before function B, then A should be defined before B
- Functions should be small, do one thing, and have descriptive names
- NO COMMENTS in code - zero tolerance for any comments, express yourself only in logs
- Clean up any TODO items from implementation phase
- Code should read like well-written prose

## Refactoring Document Structure

### Abstract Template
```swift
/*
# REFACTORING DOCUMENT: [FileName].swift

## Current State: [✅ PROPERLY ORDERED | ⚠️ NEEDS REFACTORING]

### [Class/Struct/Enum/Protocol/Extension]: [Name] ([Type Annotations])

#### Constants:
- apiKey: String (public, let)
- baseURL: URL (public, let)
- timeout: TimeInterval (public, let)
- cache: NSCache (private, let)
- decoder: JSONDecoder (private, let)

#### Properties:
- currentUser: User? (public, var) → mutated in: login(user), logout(nil)
- isConnected: Bool (public, var) → mutated in: connect(true), disconnect(false)
- connectionState: State (private, var) → mutated in: updateState(newState)
- retryCount: Int (private, var) → mutated in: handleError(+1), resetRetry(0)

#### Computed Properties:
- canRetry: Bool (public, get-only) → uses: retryCount, maxRetries
- isAuthenticated: Bool (public, get-only) → uses: currentUser
- timeoutRemaining: TimeInterval (private, get-only) → uses: startTime, timeout

#### Functions:
Line [X]: [functionName]([params]) → internalFunction(), ExternalClass.externalMethod() | (leaf)
  → log: "Message being logged"
  → error: "Error message being logged"
  → debug: "Debug message being logged"

### Global [Functions/Variables]:
- [name]: [Type] ([access level])
*/
```

**Important Notes:**
- **Computed Properties**: MUST include `→ uses:` to show what data/properties the computed property accesses
- **Functions**: Do NOT mention `log()`, `error()`, or `debugLog()` functions in the dependency tree (line showing function calls)
- **Function Calls**: Use `→` to show internal functions and external methods called (with dot notation for external)
- **Log/Error/Debug Messages**: DO include separate lines showing log, error, and debug messages (in that order) that the function outputs
- **Document Order**: The refactoring document MUST reflect the EXACT order of elements as they appear in the source code, even if computed properties and functions are interleaved

### Member Ordering Rules (Ideal Target):
1. **Constants (let)** - Immutable values first (alphabetical within public/private groups)
2. **Stored Properties (var)** - Mutable state (alphabetical within public/private groups)
3. **Computed Properties** - Derived values (alphabetical within public/private groups)
4. **Initializers** - Object creation
5. **Functions** - Methods in order of dependency (caller before callee)
6. **Deinitializers** - Cleanup last

**Important**:
- Within each category, order by: 1) Access level (public before private), 2) Alphabetically by name
- DO NOT list the same member twice - computed properties are NOT functions
- Functions follow dependency order, not alphabetical
- **The refactoring document sections should mirror the actual source code order** - if computed properties and functions are mixed in the code, document them in that mixed order with accurate line numbers

### Key:
- **Access Levels**: public, private, internal, fileprivate, open
- **Modifiers**: let, var, @State, @Binding, @Published, @ObservableObject, etc.
- **Properties**: Use → mutated in: functionName(value) to show mutations and values
- **Computed Properties**: Use → uses: propertyName, otherProperty to show data sources
- **Function Calls**: Use → to show all functions called (internal and external with dot notation) - EXCLUDE log(), error(), debugLog()
- **(leaf)**: Function makes no calls to any other functions
- **→ log**: Shows log messages printed by the function (separate line, not in function calls)
- **→ error**: Shows error messages printed by the function (separate line, not in function calls)
- **→ debug**: Shows debug messages printed by the function (separate line, not in function calls)

## Run

```bash
./scripts/deploy.sh
```

After making any code changes, always run this script to build, deploy, and run the app.

Optional: Specify device type (defaults to iphone):
```bash
./scripts/deploy.sh iphone  # Deploy to iPhone
./scripts/deploy.sh ipad    # Deploy to iPad
```

