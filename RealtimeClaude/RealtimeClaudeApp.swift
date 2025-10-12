/*
# REFACTORING DOCUMENT: RealtimeClaudeApp.swift

## Current State: ✅ PROPERLY ORDERED

### Struct: RealtimeClaudeApp (@main, App)

#### Computed Properties:
Line 5: body: some Scene (public, get-only) → uses: none

### Struct: ContentView (View)

#### Properties:
- showLogs: Bool (private, @State var) → mutated in: WorkView binding, LogListView binding

#### Computed Properties:
Line 18: body: some View (public, get-only) → uses: showLogs
*/

import SwiftUI

@main
struct RealtimeClaudeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .rotationEffect(Angle(degrees: 180))
                .statusBarHidden()
                .preferredColorScheme(.dark)
        }
    }
}

struct ContentView: View {
    @State private var showLogs = false

    var body: some View {
        ZStack {
            Color.white
                .ignoresSafeArea()

            WorkView(showLogs: $showLogs)

            if showLogs {
                LogListView(showLogs: $showLogs)
            }
        }
        .ignoresSafeArea(.all)
    }
}
