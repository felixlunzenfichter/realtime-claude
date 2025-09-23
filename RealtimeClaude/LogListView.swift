import SwiftUI
import Combine
import Observation

@Observable
class LogListViewModel {
    var logs: [LogMessage] = []
    var transmittedLogIds: [String] = []
    var sessionNumber: Int = 0
    var uptimeToday: Int = 0
    var uptimeTotal: Int = 0
    var totalLogs: Int = 0
    private var cancellables = Set<AnyCancellable>()
    let webSocketManager = WebSocketManager()

    var sessionStartTime: Date? {
        logs.last?.timestamp
    }

    var currentSessionTime: Int {
        guard let sessionStart = sessionStartTime else { return 0 }

        guard let lastAckId = transmittedLogIds.last,
              let lastAckLog = logs.first(where: { $0.id.uuidString == lastAckId }) else {
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

    func setupLogSubscription() {
        Logger.shared.logsSubject
            .sink { [weak self] logs in
                self?.logs = logs
            }
            .store(in: &cancellables)
    }

    func setupTransmittedIdsSubscription() {
        Logger.shared.transmittedLogIdsSubject
            .sink { [weak self] transmittedIds in
                self?.transmittedLogIds = transmittedIds
            }
            .store(in: &cancellables)
    }

    func setupSessionNumberSubscription() {
        Logger.shared.sessionNumberSubject
            .sink { [weak self] sessionNumber in
                self?.sessionNumber = sessionNumber
            }
            .store(in: &cancellables)
    }

    func setupUptimeTodaySubscription() {
        Logger.shared.uptimeTodaySubject
            .sink { [weak self] uptimeToday in
                self?.uptimeToday = uptimeToday
            }
            .store(in: &cancellables)
    }

    func setupUptimeTotalSubscription() {
        Logger.shared.uptimeTotalSubject
            .sink { [weak self] uptimeTotal in
                self?.uptimeTotal = uptimeTotal
            }
            .store(in: &cancellables)
    }

    func setupTotalLogsSubscription() {
        Logger.shared.totalLogsSubject
            .sink { [weak self] totalLogs in
                self?.totalLogs = totalLogs
            }
            .store(in: &cancellables)
    }

    init() {
        setupLogSubscription()
        setupTransmittedIdsSubscription()
        setupSessionNumberSubscription()
        setupUptimeTodaySubscription()
        setupUptimeTotalSubscription()
        setupTotalLogsSubscription()
    }
}

struct LogListView: View {
    @State private var viewModel = LogListViewModel()

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

            if viewModel.logs.isEmpty {
                Spacer()
                Text("No logs yet")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.logs) { log in
                            LogRowView(log: log, transmittedIds: viewModel.transmittedLogIds)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}

struct LogRowView: View {
    let log: LogMessage
    let transmittedIds: [String]

    var isTransmitted: Bool {
        transmittedIds.contains(log.id.uuidString)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isTransmitted ? Color.green : Color.red)
                    .frame(width: 8, height: 8)

                Text(log.type.label)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(log.type.color)

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

            Text(log.message)
                .font(.body)
                .foregroundColor(log.type.color)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(8)
    }
}
