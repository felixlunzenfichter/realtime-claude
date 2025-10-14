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
                    }
            }
        }
    }
}

struct ContentView: View {
    @State private var showLogs = false
    @State private var safeAreaInsets: EdgeInsets = .init()

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
            .onAppear {
                safeAreaInsets = geometry.safeAreaInsets

                let screenHeight = Int(geometry.size.height)

                UserDefaults.standard.set(screenHeight, forKey: "SCREEN_HEIGHT")
                UserDefaults.standard.set(Int(safeAreaInsets.top), forKey: "SAFE_AREA_TOP")
                UserDefaults.standard.set(Int(safeAreaInsets.bottom), forKey: "SAFE_AREA_BOTTOM")

                log("📱 Screen height: \(screenHeight), top safe area: \(Int(safeAreaInsets.top)), bottom safe area: \(Int(safeAreaInsets.bottom))")
            }
        }
    }
}
