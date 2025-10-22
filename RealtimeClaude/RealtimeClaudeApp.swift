/*
# RealtimeClaudeApp - Complete Specification

## Struct: RealtimeClaudeApp (@main, App)

### Properties
- isInitialized: Bool (@State) = false → onAppear: true after UserDefaults set

### Computed Properties
- body: some Scene → GeometryReader, if isInitialized: ContentView else: ProgressView, onAppear: UserDefaults.set("SCREEN_HEIGHT", "SAFE_AREA_TOP", "SAFE_AREA_BOTTOM"), isInitialized=true

## Struct: ContentView (View)

### Properties
- showLogs: Bool (@State) = false → WorkView, LogListView bindings

### Computed Properties
- body: some View → ZStack, WorkView, if showLogs: LogListView
*/

import SwiftUI

var ACTUAL_SCREEN_HEIGHT: CGFloat {
    let screenHeight = CGFloat(UserDefaults.standard.double(forKey: "SCREEN_HEIGHT"))
    let safeTop = CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_TOP"))
    let safeBottom = CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_BOTTOM"))
    return screenHeight + safeTop + safeBottom
}

@main
struct RealtimeClaudeApp: App {
    @State private var isInitialized = false

    var body: some Scene {
        WindowGroup {
            GeometryReader { geometry in
                if isInitialized {
                    ContentView()
                        .rotationEffect(Angle(degrees: 180))
                        .statusBarHidden()
                        .preferredColorScheme(.dark)
                } else {
                    ProgressView()
                        .scaleEffect(2)
                        .onAppear {
                            let screenHeight = geometry.size.height
                            let safeTop = geometry.safeAreaInsets.top
                            let safeBottom = geometry.safeAreaInsets.bottom

                            UserDefaults.standard.set(screenHeight, forKey: "SCREEN_HEIGHT")
                            UserDefaults.standard.set(safeTop, forKey: "SAFE_AREA_TOP")
                            UserDefaults.standard.set(safeBottom, forKey: "SAFE_AREA_BOTTOM")

                            log("📱 Screen height: \(Int(screenHeight)), top safe area: \(Int(safeTop)), bottom safe area: \(Int(safeBottom))")

                            isInitialized = true
                        }
                }
            }
        }
    }
}

struct ContentView: View {
    @State private var showLogs = false

    var body: some View {
        ZStack {
            WorkView(showLogs: $showLogs)

            if showLogs {
                LogListView(showLogs: $showLogs)
            }
        }
        .offset(y: CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_TOP")))
    }
}
