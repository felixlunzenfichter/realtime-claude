import SwiftUI

@main
struct RealtimeClaudeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .rotationEffect(.degrees(180))
                .statusBarHidden()
        }
    }
}

struct ContentView: View {
    var body: some View {
        LogListView()
    }
}
