import SwiftUI

struct LogListView: View {
    var body: some View {
        VStack(spacing: 0) {
            Text("Logs")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding()
            
            if Logger.logs.isEmpty {
                Spacer()
                Text("No logs yet")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Logger.logs) { log in
                            LogRowView(log: log)
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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // First line: Type, Date, File, Function
            HStack(spacing: 8) {
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
            
            // Second line: Message
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