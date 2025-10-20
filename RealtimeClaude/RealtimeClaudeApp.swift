/*
# RealtimeClaudeApp - Complete Specification

## Struct: RealtimeClaudeApp (@main, App)

### Computed Properties
- body: some Scene → GeometryReader, ContentView, onAppear: UserDefaults.set("SCREEN_HEIGHT", "SAFE_AREA_TOP", "SAFE_AREA_BOTTOM")

## Struct: ContentView (View)

### Properties
- showLogs: Bool (@State) = false → WorkView, LogListView bindings

### Computed Properties
- body: some View → uses: showLogs
*/

import SwiftUI

@main
struct RealtimeClaudeApp: App {
    var body: some Scene {
        WindowGroup {
            GeometryReader { geometry in
                ContentView()
                    .rotationEffect(Angle(degrees: 180))
                    .statusBarHidden()
                    .preferredColorScheme(.dark)
                    .onAppear {
                        let screenHeight = geometry.size.height
                        let safeTop = geometry.safeAreaInsets.top
                        let safeBottom = geometry.safeAreaInsets.bottom

                        UserDefaults.standard.set(screenHeight, forKey: "SCREEN_HEIGHT")
                        UserDefaults.standard.set(safeTop, forKey: "SAFE_AREA_TOP")
                        UserDefaults.standard.set(safeBottom, forKey: "SAFE_AREA_BOTTOM")

                        log("📱 Screen height: \(Int(screenHeight)), top safe area: \(Int(safeTop)), bottom safe area: \(Int(safeBottom))")
                    }
            }
        }
    }
}

struct ContentView: View {
    @State private var showLogs = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.white
                    .ignoresSafeArea()

                WorkView(showLogs: $showLogs)
                    .ignoresSafeArea()

                if showLogs {
                    LogListView(showLogs: $showLogs)
                        .ignoresSafeArea()
                }
            }
        }
    }
}
