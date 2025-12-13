import SwiftUI
import Combine
import Observation

@Observable
class LogListViewModel {
    var debugLogs: [(LogMessage, Int)] = []
    var logs: [LogMessage] = []
    var sessionNumber: Int = 0
    var showDebugLogs: Bool = false
    var showErrorLogs: Bool = true
    var showRegularLogs: Bool = true
    var successfulTests: Int = 0
    var totalLogs: Int = 0
    var totalTests: Int = 0
    var transmittedLogIds: [String] = []
    var uptimeToday: Int = 0
    var uptimeTotal: Int = 0
    var previousRunFailed: Bool = false

    private var cancellables = Set<AnyCancellable>()

    var combinedLogs: [(LogMessage, Int?)] {
        let recentLogs = Array(logs.suffix(1000))
        var combined: [(LogMessage, Int?)] = []

        if showRegularLogs && showErrorLogs {
            combined.append(contentsOf: recentLogs.map { ($0, nil) })
        } else if showRegularLogs && !showErrorLogs {
            let regularLogs = recentLogs.filter { $0.type != .error }
            combined.append(contentsOf: regularLogs.map { ($0, nil) })
        } else if !showRegularLogs && showErrorLogs {
            let errorLogs = recentLogs.filter { $0.type == .error }
            combined.append(contentsOf: errorLogs.map { ($0, nil) })
        }

        if showDebugLogs {
            combined.append(contentsOf: debugLogs.map { ($0.0, $0.1) })
        }

        return combined.sorted { $0.0.timestamp < $1.0.timestamp }
    }

    var currentSessionTime: Int {
        guard let sessionStart = sessionStartTime else { return 0 }

        guard let lastAckId = transmittedLogIds.last,
              let lastAckLog = logs.first(where: { $0.id == lastAckId }) else {
            return 0
        }

        return Int(lastAckLog.timestamp.timeIntervalSince(sessionStart) * 1000)
    }

    var errorLogsCount: Int {
        return logs.filter { $0.type == .error }.count
    }

    var regularLogsCount: Int {
        return logs.count
    }

    var sessionLogsCount: Int {
        transmittedLogIds.count
    }

    var sessionStartTime: Date? {
        logs.last?.timestamp
    }

    var testsColor: Color {
        if totalTests == 0 { return .gray }
        let percentage = Double(successfulTests) / Double(totalTests)

        var red: Double
        var green: Double

        if percentage <= 0.5 {
            red = 1.0
            green = percentage * 2.0
        } else {
            red = 2.0 - (percentage * 2.0)
            green = 1.0
        }

        return Color(red: red, green: green, blue: 0)
    }

    var todayUptimeColor: Color {
        let hours = uptimeTodayTotal / (1000 * 60 * 60)
        if hours < 4 {
            return .green
        } else if hours < 5 {
            return .orange
        } else {
            return .red
        }
    }

    var uptimeTodayTotal: Int {
        uptimeToday + currentSessionTime
    }

    var uptimeTotalTotal: Int {
        uptimeTotal + currentSessionTime
    }

    init() {
        setupSubscription(logger.logsSubject) { self.logs = $0 }
        setupSubscription(logger.debugLogsSubject) { self.debugLogs = $0 }
        setupSubscription(logger.transmittedLogIdsSubject) { self.transmittedLogIds = $0 }

        setupSubscription(logger.sessionStatsSubject) { stats in
            self.sessionNumber = stats.sessionNumber
            self.uptimeTotal = stats.totalUptime
            self.uptimeToday = stats.todayUptime
            self.totalLogs = stats.totalLogs
            self.totalTests = stats.totalTests
            self.previousRunFailed = stats.previousRunFailed
        }

        setupSubscription(logger.testsPassedSubject) { self.successfulTests = $0 }
    }

    func setupSubscription<T>(_ subject: CurrentValueSubject<T, Never>, updateProperty: @escaping (T) -> Void) {
        subject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self = self else { return }
                updateProperty(value)
            }
            .store(in: &cancellables)
    }
}

struct LogListView: View {
    @Binding var showLogs: Bool
    @Bindable var viewModel: LogListViewModel

    var isIPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    var body: some View {
        ZStack {
            Color(UIColor.systemBackground)
                .ignoresSafeArea()

            if viewModel.combinedLogs.isEmpty {
                VStack {
                    Spacer()
                    Text("No logs yet")
                        .font(.title2)
                        .foregroundColor(.secondary.opacity(0.5))
                    Spacer()
                }
                .frame(height: ACTUAL_SCREEN_HEIGHT)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            Spacer()
                                .frame(height: CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_BOTTOM")) * 2)
                                .id("topSpacer")

                            ForEach(Array(viewModel.combinedLogs.enumerated()), id: \.0) { index, item in
                                let (log, count) = item
                                LogRowView(log: log, isTransmitted: viewModel.transmittedLogIds.contains(log.id), count: count)
                                    .id(index)
                            }

                            Spacer()
                                .frame(height: CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_TOP")) * 2)
                                .id("bottomSpacer")
                        }
                        .padding(.horizontal, 12)
                    }
                    .frame(height: ACTUAL_SCREEN_HEIGHT)
                    .onChange(of: viewModel.combinedLogs.count) { _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo("bottomSpacer", anchor: .top)
                            }
                        }
                    }
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo("bottomSpacer", anchor: .top)
                            }
                        }
                    }
                }
            }


            VStack {
                TimelineView(.periodic(from: Date(), by: 1)) { _ in
                if isIPhone {
                    VStack(spacing: 0) {
                        HStack(spacing: 15) {
                            Spacer()

                            VStack(alignment: .center, spacing: 0) {
                                Text("Total")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(viewModel.uptimeTotalTotal.formattedMilliseconds)
                                    .font(.system(size: 15))
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                            }

                            VStack(alignment: .center, spacing: 0) {
                                Text("All Logs")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("\(viewModel.totalLogs + viewModel.sessionLogsCount)")
                                    .font(.system(size: 15))
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                            }

                            VStack(alignment: .center, spacing: 0) {
                                Text("Today")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(viewModel.uptimeTodayTotal.formattedMilliseconds)
                                    .font(.system(size: 15))
                                    .fontWeight(.medium)
                                    .foregroundColor(viewModel.todayUptimeColor)
                            }

                            Spacer()
                        }
                        .padding(.horizontal)

                        HStack(spacing: 15) {
                            Spacer()

                            VStack(alignment: .center, spacing: 0) {
                                Text("Session")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("#\(viewModel.sessionNumber)")
                                    .font(.system(size: 15))
                                    .fontWeight(.medium)
                                    .foregroundColor(.purple)
                            }

                            VStack(alignment: .center, spacing: 0) {
                                Text("Current")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(viewModel.currentSessionTime.formattedMilliseconds)
                                    .font(.system(size: 15))
                                    .fontWeight(.medium)
                                    .foregroundColor(.blue)
                            }

                            VStack(alignment: .center, spacing: 0) {
                                Text("Logs")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("\(viewModel.sessionLogsCount)")
                                    .font(.system(size: 15))
                                    .fontWeight(.medium)
                                    .foregroundColor(.blue)
                            }

                            VStack(alignment: .center, spacing: 0) {
                                Text("Tests")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                if viewModel.previousRunFailed {
                                    Text("✗")
                                        .font(.system(size: 20))
                                        .fontWeight(.bold)
                                        .foregroundColor(.red)
                                } else {
                                    Text("\(viewModel.successfulTests)/\(viewModel.totalTests)")
                                        .font(.system(size: 15))
                                        .fontWeight(.medium)
                                        .foregroundColor(viewModel.testsColor)
                                }
                            }

                            Spacer()
                        }
                        .padding(.horizontal)
                    }
                } else {
                    HStack(spacing: 20) {
                        Spacer()
                        VStack(alignment: .center, spacing: 2) {
                            Text("Total")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(viewModel.uptimeTotalTotal.formattedMilliseconds)
                                .font(.title3)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                                .frame(minWidth: 90)
                        }
                        .frame(minWidth: 90)

                        VStack(alignment: .center, spacing: 2) {
                            Text("All Logs")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(viewModel.totalLogs + viewModel.sessionLogsCount)")
                                .font(.title3)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                                .frame(minWidth: 60)
                        }
                        .frame(minWidth: 60)

                        VStack(alignment: .center, spacing: 2) {
                            Text("Today")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(viewModel.uptimeTodayTotal.formattedMilliseconds)
                                .font(.title3)
                                .fontWeight(.medium)
                                .foregroundColor(viewModel.todayUptimeColor)
                                .frame(minWidth: 90)
                        }
                        .frame(minWidth: 90)

                        VStack(alignment: .center, spacing: 2) {
                            Text("Session")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("#\(viewModel.sessionNumber)")
                                .font(.title3)
                                .fontWeight(.medium)
                                .foregroundColor(.purple)
                                .frame(minWidth: 50)
                        }
                        .frame(minWidth: 50)

                        VStack(alignment: .center, spacing: 2) {
                            Text("Current")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(viewModel.currentSessionTime.formattedMilliseconds)
                                .font(.title3)
                                .fontWeight(.medium)
                                .foregroundColor(.blue)
                                .frame(minWidth: 70)
                        }
                        .frame(minWidth: 70)

                        VStack(alignment: .center, spacing: 2) {
                            Text("Logs")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(viewModel.sessionLogsCount)")
                                .font(.title3)
                                .fontWeight(.medium)
                                .foregroundColor(.blue)
                                .frame(minWidth: 50)
                        }
                        .frame(minWidth: 50)

                        VStack(alignment: .center, spacing: 2) {
                            Text("Tests")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if viewModel.previousRunFailed {
                                Text("✗")
                                    .font(.system(size: 28))
                                    .fontWeight(.bold)
                                    .foregroundColor(.red)
                                    .frame(minWidth: 60)
                            } else {
                                Text("\(viewModel.successfulTests)/\(viewModel.totalTests)")
                                    .font(.title3)
                                    .fontWeight(.medium)
                                    .foregroundColor(viewModel.testsColor)
                                    .frame(minWidth: 60)
                            }
                        }
                        .frame(minWidth: 60)

                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
                }
                .frame(height: CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_BOTTOM")) * 2)
                .glassEffect(.regular, in: .rect(cornerRadius: 0))

                Spacer()

                ToggleBar(items: [
                    ToggleBar.ToggleItem(
                        color: .purple,
                        isOn: .constant(false),
                        icon: "arrow.clockwise",
                        action: {
                            error("Manual restart triggered from log view")
                        }
                    ),
                    ToggleBar.ToggleItem(
                        color: .red,
                        isOn: $viewModel.showErrorLogs,
                        text: "\(viewModel.errorLogsCount)",
                        action: {
                            viewModel.showErrorLogs.toggle()
                        }
                    ),
                    ToggleBar.ToggleItem(
                        color: .orange,
                        isOn: $viewModel.showDebugLogs,
                        text: "\(viewModel.debugLogs.count)",
                        action: {
                            viewModel.showDebugLogs.toggle()
                        }
                    ),
                    ToggleBar.ToggleItem(
                        color: .green,
                        isOn: $viewModel.showRegularLogs,
                        text: "\(viewModel.regularLogsCount)",
                        action: {
                            viewModel.showRegularLogs.toggle()
                        }
                    ),
                    ToggleBar.ToggleItem(
                        color: .blue,
                        isOn: $showLogs,
                        icon: "xmark",
                        action: {
                            showLogs.toggle()
                        }
                    )
                ])
            }
        }
    }
}

struct LogRowView: View {
    let log: LogMessage
    let isTransmitted: Bool
    let count: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(count != nil ? Color.orange : (isTransmitted ? Color.green : Color.red))
                    .frame(width: 8, height: 8)

                Text("•")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(log.timestamp.formattedTimestamp)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Text("•")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(log.shortFileName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text("•")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(log.functionName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let count = count {
                    Text(String(format: "x%4d", count))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)
                        .frame(width: 40, alignment: .leading)
                }

                Spacer()
            }

            if count != nil {
                Text("[\(log.id)] \(log.message)")
                    .font(.body)
                    .foregroundColor(Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(log.message)
                    .font(.body)
                    .foregroundColor(log.type.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(UIColor.secondarySystemBackground).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.gray.opacity(0.1), lineWidth: 1)
        )
    }
}

@Observable
class DiffViewModel {
    var codeDiff: String = ""
    var scrollToLineIndex: Int? = nil

    private var previousDiffLines: [(text: String, type: DiffLineType)] = []
    private var cancellables = Set<AnyCancellable>()

    init() {
        logger.codeDiffSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] diff in
                guard let self = self else { return }

                let previousDiff = self.codeDiff
                self.codeDiff = diff

                guard !diff.isEmpty, diff != previousDiff else { return }

                self.findFirstChangedLine()
            }
            .store(in: &cancellables)
    }

    var diffLines: [(text: String, type: DiffLineType)] {
        guard !codeDiff.isEmpty else { return [] }

        return codeDiff.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let lineString = String(line)
            if lineString.hasPrefix("===") {
                return (text: lineString, type: .sectionHeader)
            } else if lineString.hasPrefix("+") {
                return (text: lineString, type: .addition)
            } else if lineString.hasPrefix("-") {
                return (text: lineString, type: .deletion)
            } else if lineString.hasPrefix("@@") {
                return (text: lineString, type: .hunk)
            } else if lineString.hasPrefix("diff --git") || lineString.hasPrefix("index") {
                return (text: lineString, type: .header)
            } else {
                return (text: lineString, type: .context)
            }
        }
    }

    func findFirstChangedLine() {
        let currentLines = diffLines

        var firstChangeIndex: Int?

        for (index, currentLine) in currentLines.enumerated() {
            guard currentLine.type == .addition || currentLine.type == .deletion else {
                continue
            }

            let text = currentLine.text
            if text.hasPrefix("---") || text.hasPrefix("+++") || text.hasPrefix("@@") {
                continue
            }

            if index >= previousDiffLines.count {
                firstChangeIndex = index
                break
            }

            let previousLine = previousDiffLines[index]
            if currentLine.text != previousLine.text {
                firstChangeIndex = index
                break
            }
        }

        previousDiffLines = currentLines

        scrollToLineIndex = nil
        scrollToLineIndex = firstChangeIndex ?? 0
    }
}

enum DiffLineType {
    case addition
    case deletion
    case hunk
    case header
    case sectionHeader
    case context

    var color: Color {
        switch self {
        case .addition:
            return .green
        case .deletion:
            return .red
        case .hunk:
            return .cyan
        case .header:
            return .purple
        case .sectionHeader:
            return .orange
        case .context:
            return .secondary
        }
    }
}

struct DiffView: View {
    @Binding var showDiff: Bool
    @Bindable var viewModel: DiffViewModel

    var body: some View {
        ZStack {
            Color(UIColor.systemBackground)
                .ignoresSafeArea()

            if viewModel.codeDiff.isEmpty {
                VStack {
                    Spacer()
                    Text("No changes")
                        .font(.title2)
                        .foregroundColor(.secondary.opacity(0.5))
                    Spacer()
                }
                .frame(height: ACTUAL_SCREEN_HEIGHT)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            Spacer()
                                .frame(height: CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_BOTTOM")) * 2)

                            ForEach(Array(viewModel.diffLines.enumerated()), id: \.offset) { index, line in
                                DiffLineView(text: line.text, type: line.type, index: index, scrollToLineIndex: viewModel.scrollToLineIndex)
                                    .id(index)
                            }

                            Spacer()
                                .frame(height: CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_TOP")) * 2)
                        }
                        .padding(.horizontal, 12)
                    }
                    .frame(height: ACTUAL_SCREEN_HEIGHT)
                    .onChange(of: viewModel.scrollToLineIndex) { _, newIndex in
                        guard let index = newIndex else { return }

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(index, anchor: .center)
                            }
                        }
                    }
                    .onAppear {
                        guard let index = viewModel.scrollToLineIndex else { return }

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(index, anchor: .center)
                            }
                        }
                    }
                }
            }

            VStack {
                Spacer()

                ToggleBar(items: [
                    ToggleBar.ToggleItem(
                        color: .blue,
                        isOn: $showDiff,
                        icon: "xmark",
                        action: {
                            showDiff.toggle()
                        }
                    )
                ])
            }
        }
    }
}

struct DiffLineView: View {
    let text: String
    let type: DiffLineType
    let index: Int
    let scrollToLineIndex: Int?

    var isHighlighted: Bool {
        guard let scrollToLineIndex = scrollToLineIndex else { return false }
        return index == scrollToLineIndex
    }

    var body: some View {
        VStack(spacing: 0) {
            if type == .sectionHeader {
                Spacer()
                    .frame(height: 16)
            }

            HStack(spacing: 0) {
                Text(text)
                    .font(.system(type == .sectionHeader ? .headline : .body, design: .monospaced))
                    .fontWeight(type == .sectionHeader ? .bold : .regular)
                    .foregroundColor(type.color)
                    .lineLimit(nil)
                    .frame(maxWidth: .infinity, alignment: type == .sectionHeader ? .center : .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                isHighlighted ? Color.yellow.opacity(0.3) : Color.clear
            )

            if type == .sectionHeader {
                Spacer()
                    .frame(height: 16)
            }
        }
    }
}