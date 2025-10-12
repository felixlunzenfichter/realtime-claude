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
                        // Get values dynamically
                        let screenHeight = geometry.size.height
                        let safeTop = geometry.safeAreaInsets.top
                        let safeBottom = geometry.safeAreaInsets.bottom

                        // Store dynamically in environment (UserDefaults)
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

                VStack {
                    VStack(spacing: 4) {
                        Text("Screen: \(Int(geometry.size.width)) × \(Int(geometry.size.height))")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.white)
                        Text("Safe T:\(Int(UserDefaults.standard.double(forKey: "SAFE_AREA_TOP"))) B:\(Int(UserDefaults.standard.double(forKey: "SAFE_AREA_BOTTOM"))) L:\(Int(UserDefaults.standard.double(forKey: "SAFE_AREA_LEADING"))) R:\(Int(UserDefaults.standard.double(forKey: "SAFE_AREA_TRAILING")))")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(6)
                    .offset(y: 40)

                    Spacer()
                }
            }
            .onAppear {
                // Capture safe area insets before they're ignored
                safeAreaInsets = geometry.safeAreaInsets

                let screenHeight = Int(geometry.size.height)
                let screenWidth = Int(geometry.size.width)

                // Store in UserDefaults for access elsewhere in the app
                UserDefaults.standard.set(screenHeight, forKey: "SCREEN_HEIGHT")
                UserDefaults.standard.set(screenWidth, forKey: "SCREEN_WIDTH")
                UserDefaults.standard.set(Int(safeAreaInsets.top), forKey: "SAFE_AREA_TOP")
                UserDefaults.standard.set(Int(safeAreaInsets.bottom), forKey: "SAFE_AREA_BOTTOM")

                // Log the values
                log("📱 Screen dimensions detected: \(screenWidth) × \(screenHeight)")
                log("📱 SCREEN_HEIGHT set to: \(screenHeight)")
                log("📱 Safe areas - Top: \(Int(safeAreaInsets.top)), Bottom: \(Int(safeAreaInsets.bottom))")
            }
        }
    }
}
