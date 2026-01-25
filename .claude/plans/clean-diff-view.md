# Plan: Redesign DiffView with Git Tree and Merge Button

## Overview

Replace the current 4-button navigation DiffView with a cleaner design that shows:
1. Active agents (running background tasks)
2. Git commit list (commits on current branch vs development)
3. Diff content (for selected commit)
4. Merge button (when PR exists)

## Current State Analysis

### DiffView (LogListView.swift lines 800-895)
- 4-button ToggleBar: prev, mode cycle, close, next
- Complex navigation modes: headers, hunks, changes, sections
- DiffViewModel tracks: currentChangeIndex, currentNavigationMode, highlightedLineIndex
- Receives diff via `logger.codeDiffSubject`

### Mac Server (mac-server.js)
- Sends `code_diff` message type (lines 1644-1698)
- Uses `get-diff.sh` script to compute diff
- Computes columns for display
- No git state info (branch, commits, PR status) currently sent

### Logger (Logger.swift)
- `codeDiffSubject: CurrentValueSubject<String, Never>` receives diff
- Handles `code_diff` message type (lines 610-618)
- No merge/PR functionality exists

## Desired State

### New Layout
```
+------------------------------------+
| Active Agents (if any)             |
| +------------------------------+   |
| | Agent abc123: Running        |   |
| +------------------------------+   |
+------------------------------------+
| Git Commits (scrollable)           |
| +------------------------------+   |
| | abc1234 feat: add button     |<- |
| | def5678 fix: update logic    |   |
| | ghi9012 test: add tests      |   |
| +------------------------------+   |
+------------------------------------+
| Diff Content (selected commit)     |
|   +++ added line                   |
|   --- removed line                 |
|   context line                     |
+------------------------------------+
| [Merge]  [X Close]                 |
| (green)  (blue)                    |
+------------------------------------+
```

## Implementation Steps

### Step 1: Add Git State Message Type to Mac Server

**File:** `scripts/mac-server.js`

Add new function to gather git state:
```javascript
function getGitState(repoPath) {
    // Get current branch
    const branch = execSync('git branch --show-current', { cwd: repoPath, encoding: 'utf8' }).trim();

    // Get commits on branch vs development
    const commits = execSync('git log development..HEAD --pretty=format:"%h|%s|%ar"', { cwd: repoPath, encoding: 'utf8' })
        .trim()
        .split('\n')
        .filter(Boolean)
        .map(line => {
            const [hash, message, timestamp] = line.split('|');
            return { hash, message, timestamp };
        });

    // Check for open PR using gh CLI
    let hasPR = false;
    let prNumber = null;
    try {
        const prInfo = execSync('gh pr view --json number,state 2>/dev/null', { cwd: repoPath, encoding: 'utf8' });
        const pr = JSON.parse(prInfo);
        if (pr.state === 'OPEN') {
            hasPR = true;
            prNumber = pr.number;
        }
    } catch (e) {
        // No PR exists
    }

    return { branch, commits, hasPR, prNumber };
}
```

Send git state along with diff:
```javascript
function sendGitDiffToiOS(force = false) {
    // ... existing diff logic ...

    const gitState = getGitState(repoPath);

    const diffMessage = {
        type: 'code_diff',
        diff: columns.join('\n\n--- COLUMN ---\n\n'),
        columns: columns,
        gitState: gitState,  // NEW
        timestamp: Date.now()
    };

    // ... send message ...
}
```

Add merge PR handler:
```javascript
function handleMergePRMessage(logData) {
    const { prNumber } = logData;
    const repoPath = getRepoPath();

    try {
        execSync(`gh pr merge ${prNumber} --merge`, { cwd: repoPath, encoding: 'utf8' });
        log(`Merged PR #${prNumber}`, 'handleMergePRMessage');

        // Send updated git state after merge
        sendGitDiffToiOS(true);
    } catch (err) {
        error(`Failed to merge PR: ${err.message}`, 'handleMergePRMessage');
    }
}
```

### Step 2: Update Logger Protocol and Implementation

**File:** `RealtimeClaude/Logger.swift`

Add new subjects and method to protocol:
```swift
protocol LoggerProtocol {
    // ... existing ...
    var gitStateSubject: CurrentValueSubject<GitState?, Never> { get }
    func sendMergePRToMac(prNumber: Int)
}
```

Add GitState model:
```swift
struct GitCommit: Codable {
    let hash: String
    let message: String
    let timestamp: String
}

struct GitState: Codable {
    let branch: String
    let commits: [GitCommit]
    let hasPR: Bool
    let prNumber: Int?
}
```

Update handleCodeDiffMessage to parse gitState:
```swift
private func handleCodeDiffMessage(_ jsonData: [String: Any]) {
    guard let diff = jsonData["diff"] as? String else {
        error("diff was nil in code_diff message")
        return
    }

    codeDiffSubject.send(diff)

    // Parse git state if present
    if let gitStateDict = jsonData["gitState"] as? [String: Any] {
        let branch = gitStateDict["branch"] as? String ?? ""
        let hasPR = gitStateDict["hasPR"] as? Bool ?? false
        let prNumber = gitStateDict["prNumber"] as? Int

        var commits: [GitCommit] = []
        if let commitsArray = gitStateDict["commits"] as? [[String: Any]] {
            commits = commitsArray.compactMap { dict in
                guard let hash = dict["hash"] as? String,
                      let message = dict["message"] as? String,
                      let timestamp = dict["timestamp"] as? String else { return nil }
                return GitCommit(hash: hash, message: message, timestamp: timestamp)
            }
        }

        gitStateSubject.send(GitState(branch: branch, commits: commits, hasPR: hasPR, prNumber: prNumber))
    }
}
```

Add sendMergePRToMac:
```swift
func sendMergePRToMac(prNumber: Int) {
    let mergeMessage: [String: Any] = [
        "type": "merge_pr",
        "prNumber": prNumber
    ]

    guard let jsonData = try? JSONSerialization.data(withJSONObject: mergeMessage) else {
        error("Failed to serialize merge_pr message")
        return
    }

    sendMessage(jsonData, messageType: "merge_pr", logMessage: "Sending merge request for PR #\(prNumber)")
}
```

### Step 3: Redesign DiffView

**File:** `RealtimeClaude/LogListView.swift`

Replace DiffView completely:

```swift
@Observable
class DiffViewModel {
    var codeDiff: String = ""
    var gitState: GitState?
    var selectedCommitHash: String?

    private var cancellables = Set<AnyCancellable>()

    init() {
        logger.codeDiffSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] diff in
                self?.codeDiff = diff
            }
            .store(in: &cancellables)

        logger.gitStateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.gitState = state
                // Select first commit by default
                if self?.selectedCommitHash == nil {
                    self?.selectedCommitHash = state?.commits.first?.hash
                }
            }
            .store(in: &cancellables)
    }

    var diffLines: [(text: String, type: DiffLineType)] {
        // ... existing parsing logic ...
    }
}

struct DiffView: View {
    @Binding var showDiff: Bool
    @Bindable var viewModel: DiffViewModel

    var body: some View {
        ZStack {
            Color(UIColor.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Active Agents Section (placeholder for future)
                // AgentsSection()

                // Git Commits Section
                if let gitState = viewModel.gitState, !gitState.commits.isEmpty {
                    CommitListSection(
                        commits: gitState.commits,
                        selectedHash: $viewModel.selectedCommitHash
                    )
                }

                // Diff Content Section
                DiffContentSection(viewModel: viewModel)

                // Bottom Bar: Merge + Close
                BottomBar(
                    gitState: viewModel.gitState,
                    showDiff: $showDiff
                )
            }
        }
    }
}

struct CommitListSection: View {
    let commits: [GitCommit]
    @Binding var selectedHash: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Commits")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(commits, id: \.hash) { commit in
                        CommitBadge(
                            commit: commit,
                            isSelected: commit.hash == selectedHash
                        )
                        .onTapGesture {
                            selectedHash = commit.hash
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background(Color(UIColor.secondarySystemBackground))
    }
}

struct CommitBadge: View {
    let commit: GitCommit
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(commit.hash)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.bold)
                .foregroundColor(isSelected ? .white : .blue)

            Text(commit.message)
                .font(.caption2)
                .foregroundColor(isSelected ? .white.opacity(0.8) : .primary)
                .lineLimit(1)

            Text(commit.timestamp)
                .font(.caption2)
                .foregroundColor(isSelected ? .white.opacity(0.6) : .secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.blue : Color(UIColor.tertiarySystemBackground))
        )
    }
}

struct DiffContentSection: View {
    @Bindable var viewModel: DiffViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(viewModel.diffLines.enumerated()), id: \.offset) { index, line in
                    DiffLineView(text: line.text, type: line.type, index: index, currentLineIndex: nil)
                        .id(index)
                }
            }
            .padding(.horizontal, 12)
        }
    }
}

struct BottomBar: View {
    let gitState: GitState?
    @Binding var showDiff: Bool

    var body: some View {
        HStack(spacing: 16) {
            // Merge Button (only if PR exists)
            if let gitState = gitState, gitState.hasPR, let prNumber = gitState.prNumber {
                Button(action: {
                    logger.sendMergePRToMac(prNumber: prNumber)
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Merge PR #\(prNumber)")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.green)
                    .cornerRadius(12)
                }
            }

            Spacer()

            // Close Button
            Button(action: {
                showDiff = false
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.blue)
                    .cornerRadius(12)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Color(UIColor.systemBackground)
                .glassEffect(.regular, in: .rect(cornerRadius: 0))
        )
    }
}
```

### Step 4: Clean Up Removed Code

Remove from LogListView.swift:
- `NavigationMode` enum (lines 526-570)
- Navigation methods in DiffViewModel: `cycleNavigationMode`, `navigateToNextChange`, `navigateToPreviousChange`, `findFirstChangedLine`, `modeSpecificIndices`, `changeChunkIndices`, `changeIndices`
- Old ToggleBar in DiffView
- `scrollToLineIndex`, `currentChangeIndex`, `currentNavigationMode`, `highlightedLineIndex` from DiffViewModel

## Testing Checklist

### Automated Tests
1. Verify git state is sent with code_diff message
2. Verify commits list parses correctly
3. Verify merge_pr message sends correctly

### Manual Tests
1. View shows commits on current branch
2. Tapping commit shows correct diff (initially: just full diff)
3. Merge button appears only when PR exists
4. Merge button triggers actual PR merge
5. Close button works

## Files Changed Summary

| File | Changes |
|------|---------|
| `scripts/mac-server.js` | Add `getGitState()`, update `sendGitDiffToiOS()`, add `handleMergePRMessage()` |
| `RealtimeClaude/Logger.swift` | Add `GitState`, `GitCommit` models, `gitStateSubject`, `sendMergePRToMac()`, update `handleCodeDiffMessage()` |
| `RealtimeClaude/LogListView.swift` | Complete redesign of `DiffView`, `DiffViewModel`, add `CommitListSection`, `CommitBadge`, `DiffContentSection`, `BottomBar` |

## Future Enhancements (Out of Scope)

1. Active Agents section - requires agent tracking infrastructure
2. Per-commit diff view - requires Mac server to compute diff for specific commits
3. Branch switching - would need full git control from iOS
