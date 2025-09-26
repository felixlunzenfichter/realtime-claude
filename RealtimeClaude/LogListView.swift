import SwiftUI
import Combine
import Observation

@Observable
class LogListViewModel {
    var logs: [LogMessage] = []
    var debugLogs: [(LogMessage, Int)] = []
    var combinedLogs: [(LogMessage, Int?)] = []
    var transmittedLogIds: [String] = []
    var sessionNumber: Int = 0
    var uptimeToday: Int = 0
    var uptimeTotal: Int = 0
    var totalLogs: Int = 0
    private var cancellables = Set<AnyCancellable>()
    let realtimeAPI = RealtimeAPI.shared

    var sessionStartTime: Date? {
        logs.last?.timestamp
    }

    var currentSessionTime: Int {
        guard let sessionStart = sessionStartTime else { return 0 }

        guard let lastAckId = transmittedLogIds.last,
              let lastAckLog = logs.first(where: { $0.id == lastAckId }) else {
            return 0
        }

        return Int(lastAckLog.timestamp.timeIntervalSince(sessionStart) * 1000)
    }

    var currentSessionTimeFormatted: String {
        let milliseconds = currentSessionTime
        let seconds = milliseconds / 1000
        let minutes = seconds / 60
        let hours = minutes / 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes % 60, seconds % 60)
        } else {
            return String(format: "%02d:%02d", minutes, seconds % 60)
        }
    }

    var sessionLogsCount: Int {
        transmittedLogIds.count
    }

    var uptimeTodayTotal: Int {
        uptimeToday + currentSessionTime
    }

    var uptimeTotalTotal: Int {
        uptimeTotal + currentSessionTime
    }

    var uptimeTodayFormatted: String {
        formatMilliseconds(uptimeTodayTotal)
    }

    var uptimeTotalFormatted: String {
        formatMilliseconds(uptimeTotalTotal)
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

    func formatMilliseconds(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1000
        let minutes = seconds / 60
        let hours = minutes / 60

        if hours > 0 {
            return String(format: "%dh %dm %ds", hours, minutes % 60, seconds % 60)
        } else if minutes > 0 {
            return String(format: "%dm %ds", minutes, seconds % 60)
        } else {
            return String(format: "%ds", seconds)
        }
    }

    init() {
        setupSubscription(Logger.shared.logsSubject) { [weak self] logs in
            self?.logs = logs
            self?.updateCombinedLogs()
        }
        setupSubscription(Logger.shared.debugLogsSubject) { [weak self] debugLogs in
            self?.debugLogs = debugLogs
            self?.updateCombinedLogs()
        }
        setupSubscription(Logger.shared.transmittedLogIdsSubject) { self.transmittedLogIds = $0 }
        setupSubscription(Logger.shared.sessionNumberSubject) { self.sessionNumber = $0 }
        setupSubscription(Logger.shared.uptimeTodaySubject) { self.uptimeToday = $0 }
        setupSubscription(Logger.shared.uptimeTotalSubject) { self.uptimeTotal = $0 }
        setupSubscription(Logger.shared.totalLogsSubject) { self.totalLogs = $0 }
    }
    
    func updateCombinedLogs() {
        var combined: [(LogMessage, Int?)] = logs.map { ($0, nil) }
        combined.append(contentsOf: debugLogs.map { ($0.0, $0.1) })
        combinedLogs = combined.sorted { $0.0.timestamp > $1.0.timestamp }
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
    @State private var viewModel = LogListViewModel()
    @Binding var showLogs: Bool

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.periodic(from: Date(), by: 1)) { _ in
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Total")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(viewModel.uptimeTotalFormatted)
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
                        Text(viewModel.uptimeTodayFormatted)
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
                        Text(viewModel.currentSessionTimeFormatted)
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
            .padding(.horizontal)
            .padding(.vertical)

            if viewModel.combinedLogs.isEmpty {
                Spacer()
                Text("No logs yet")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(viewModel.combinedLogs.enumerated()), id: \.0) { _, item in
                            let (log, count) = item
                            LogRowView(log: log, isTransmitted: viewModel.transmittedLogIds.contains(log.id), count: count)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .background(Color(UIColor.systemBackground))
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

                Text(log.type.label)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(log.type.color)

                if let count = count {
                    Text("x\(count)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)
                }

                Text("•")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(log.formattedTimestamp)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("•")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(log.shortFileName)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("•")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(log.functionName)
                    .font(.caption)
                    .foregroundColor(.secondary)

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
        .padding(10)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(8)
    }
}
