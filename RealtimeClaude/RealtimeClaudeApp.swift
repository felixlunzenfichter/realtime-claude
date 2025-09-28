import SwiftUI

@main
struct RealtimeClaudeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .rotationEffect(Angle(degrees: 180))
                .statusBarHidden()
        }
    }
}

struct ContentView: View {
    @State private var showLogs = true

    var body: some View {
        ZStack {
            WorkView()
                .ignoresSafeArea()
            if showLogs {
                LogListView(showLogs: $showLogs)
                    .ignoresSafeArea()
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        withAnimation(.spring()) {
                            showLogs.toggle()
                        }
                    }) {
                        Image(systemName: showLogs ? "waveform" : "list.bullet")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .padding()
                }
                Spacer()
            }
        }
    }
}

