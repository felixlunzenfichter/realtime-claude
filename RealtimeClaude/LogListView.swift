/*
# LogListView - Complete Specification

## Class: LogListViewModel (@Observable)

### Properties
- logs: [LogMessage] = [] → setupSubscription(): logger.logsSubject
- debugLogs: [(LogMessage, Int)] = [] → setupSubscription(): logger.debugLogsSubject
- transmittedLogIds: [String] = [] → setupSubscription(): logger.transmittedLogIdsSubject
- sessionNumber: Int = 0 → setupSubscription(): logger.sessionNumberSubject
- uptimeToday: Int = 0 → setupSubscription(): logger.uptimeTodaySubject
- uptimeTotal: Int = 0 → setupSubscription(): logger.uptimeTotalSubject
- totalLogs: Int = 0 → setupSubscription(): logger.totalLogsSubject
- showDebugLogs: Bool = false → user toggle
- showRegularLogs: Bool = true → user toggle
- showErrorLogs: Bool = true → user toggle
- cancellables: Set<AnyCancellable> = [] → setupSubscription(): store

### Computed Properties
- combinedLogs: [(LogMessage, Int?)] → uses: showRegularLogs, showErrorLogs, showDebugLogs, logs, debugLogs
- regularLogsCount: Int → uses: logs
- errorLogsCount: Int → uses: logs
- sessionStartTime: Date? → uses: logs
- currentSessionTime: Int → uses: sessionStartTime, transmittedLogIds, logs
- sessionLogsCount: Int → uses: transmittedLogIds
- uptimeTodayTotal: Int → uses: uptimeToday, currentSessionTime
- uptimeTotalTotal: Int → uses: uptimeTotal, currentSessionTime
- todayUptimeColor: Color → uses: uptimeTodayTotal

### Functions
- init() → setupSubscription()
- setupSubscription() → subject.receive(), subject.sink(), cancellables.insert()

## Struct: LogListView (View)

### Properties
- showLogs: Bool (@Binding)
- viewModel: LogListViewModel (@State) = LogListViewModel()

### Computed Properties
- isIPhone: Bool → uses: UIDevice.current.userInterfaceIdiom
- body: some View → uses: viewModel, showLogs, isIPhone

## Struct: LogRowView (View)

### Constants
- log: LogMessage
- isTransmitted: Bool
- count: Int?

### Computed Properties
- body: some View → uses: log, isTransmitted, count
*/

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
    var totalLogs: Int = 0
    var transmittedLogIds: [String] = []
    var uptimeToday: Int = 0
    var uptimeTotal: Int = 0

    private var cancellables = Set<AnyCancellable>()

    var combinedLogs: [(LogMessage, Int?)] {
        var combined: [(LogMessage, Int?)] = []

        if showRegularLogs && showErrorLogs {
            combined.append(contentsOf: logs.map { ($0, nil) })
        } else if showRegularLogs && !showErrorLogs {
            let regularLogs = logs.filter { $0.type != .error }
            combined.append(contentsOf: regularLogs.map { ($0, nil) })
        } else if !showRegularLogs && showErrorLogs {
            let errorLogs = logs.filter { $0.type == .error }
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
        setupSubscription(logger.sessionNumberSubject) { self.sessionNumber = $0 }
        setupSubscription(logger.uptimeTodaySubject) { self.uptimeToday = $0 }
        setupSubscription(logger.uptimeTotalSubject) { self.uptimeTotal = $0 }
        setupSubscription(logger.totalLogsSubject) { self.totalLogs = $0 }
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
    @State private var viewModel = LogListViewModel()

    var ACTUAL_SCREEN_HEIGHT: CGFloat {
        let screenHeight = CGFloat(UserDefaults.standard.double(forKey: "SCREEN_HEIGHT"))
        let safeTop = CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_TOP"))
        let safeBottom = CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_BOTTOM"))
        return screenHeight + safeTop + safeBottom
    }

    var isIPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    var body: some View {
        ZStack {
            Color(UIColor.systemBackground)
                .ignoresSafeArea()

            VStack {
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
                        VStack(alignment: .leading, spacing: 6) {
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
            }
            .offset(y: -CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_BOTTOM")))


            VStack {
                TimelineView(.periodic(from: Date(), by: 1)) { _ in
                if isIPhone {
                    VStack(spacing: 4) {
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
                        .padding(.vertical, 4)
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

                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal)
                    }
                } else {
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Total")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(viewModel.uptimeTotalTotal.formattedMilliseconds)
                                .font(.title3)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                                .frame(minWidth: 90, alignment: .leading)
                        }
                        .frame(minWidth: 90)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("All Logs")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(viewModel.totalLogs + viewModel.sessionLogsCount)")
                                .font(.title3)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                                .frame(minWidth: 60, alignment: .leading)
                        }
                        .frame(minWidth: 60)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Today")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(viewModel.uptimeTodayTotal.formattedMilliseconds)
                                .font(.title3)
                                .fontWeight(.medium)
                                .foregroundColor(viewModel.todayUptimeColor)
                                .frame(minWidth: 90, alignment: .leading)
                        }
                        .frame(minWidth: 90)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Session")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("#\(viewModel.sessionNumber)")
                                .font(.title3)
                                .fontWeight(.medium)
                                .foregroundColor(.purple)
                                .frame(minWidth: 50, alignment: .leading)
                        }
                        .frame(minWidth: 50)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Current")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(viewModel.currentSessionTime.formattedMilliseconds)
                                .font(.title3)
                                .fontWeight(.medium)
                                .foregroundColor(.blue)
                                .frame(minWidth: 70, alignment: .leading)
                        }
                        .frame(minWidth: 70)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Logs")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(viewModel.sessionLogsCount)")
                                .font(.title3)
                                .fontWeight(.medium)
                                .foregroundColor(.blue)
                                .frame(minWidth: 50, alignment: .leading)
                        }
                        .frame(minWidth: 50)

                        Spacer()
                    }
                }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect()
                .offset(y: -34)

                Spacer()

                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.orange.opacity(0.1))
                        .overlay(
                            VStack {
                                Spacer()
                                    .frame(height: 20)
                                HStack(spacing: 8) {
                                    Toggle(isOn: $viewModel.showDebugLogs) {
                                        EmptyView()
                                    }
                                    .toggleStyle(SwitchToggleStyle(tint: .orange))
                                    .labelsHidden()

                                    Text("\(viewModel.debugLogs.count)")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.orange)
                                }
                                Spacer()
                            }
                        )
                        .onTapGesture {
                            viewModel.showDebugLogs.toggle()
                        }

                    Rectangle()
                        .fill(Color.green.opacity(0.1))
                        .overlay(
                            VStack {
                                Spacer()
                                    .frame(height: 20)
                                HStack(spacing: 8) {
                                    Toggle(isOn: $viewModel.showRegularLogs) {
                                        EmptyView()
                                    }
                                    .toggleStyle(SwitchToggleStyle(tint: .green))
                                    .labelsHidden()

                                    Text("\(viewModel.regularLogsCount)")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.green)
                                }
                                Spacer()
                            }
                        )
                        .onTapGesture {
                            viewModel.showRegularLogs.toggle()
                        }

                    Rectangle()
                        .fill(Color.red.opacity(0.1))
                        .overlay(
                            VStack {
                                Spacer()
                                    .frame(height: 20)
                                HStack(spacing: 8) {
                                    Toggle(isOn: $viewModel.showErrorLogs) {
                                        EmptyView()
                                    }
                                    .toggleStyle(SwitchToggleStyle(tint: .red))
                                    .labelsHidden()

                                    Text("\(viewModel.errorLogsCount)")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.red)
                                }
                                Spacer()
                            }
                        )
                        .onTapGesture {
                            viewModel.showErrorLogs.toggle()
                        }

                    Rectangle()
                        .fill(Color.blue.opacity(0.1))
                        .overlay(
                            VStack {
                                Spacer()
                                    .frame(height: 20)
                                HStack(spacing: 8) {
                                    Toggle(isOn: $showLogs) {
                                        EmptyView()
                                    }
                                    .toggleStyle(SwitchToggleStyle(tint: .blue))
                                    .labelsHidden()

                                    Image(systemName: showLogs ? "eye.fill" : "eye.slash.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.blue)
                                }
                                Spacer()
                            }
                        )
                        .onTapGesture {
                            showLogs.toggle()
                        }
                }
                .frame(height: CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_TOP")) * 2)
                .glassEffect()
                .offset(y: -CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_BOTTOM")))
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
