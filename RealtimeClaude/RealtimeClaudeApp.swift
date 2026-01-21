import SwiftUI
import Combine
import Observation
import CoreMotion

var ACTUAL_SCREEN_HEIGHT: CGFloat {
    let screenHeight = CGFloat(UserDefaults.standard.double(forKey: "SCREEN_HEIGHT"))
    let safeTop = CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_TOP"))
    let safeBottom = CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_BOTTOM"))
    return screenHeight + safeTop + safeBottom
}

var ACTUAL_SCREEN_WIDTH: CGFloat {
    CGFloat(UserDefaults.standard.double(forKey: "SCREEN_WIDTH"))
}

@Observable
class ViewModel {
    var isInitialized: Bool = false
    #if IS_TEST
    var showLogs: Bool = true
    #else
    var showLogs: Bool = false
    #endif
    var showDiff: Bool = false
    var workViewModel = WorkViewModel()
    var logListViewModel = LogListViewModel()
    var diffViewModel = DiffViewModel()
}

@main
struct RealtimeClaudeApp: App {
    @State private var viewModel = ViewModel()

    var body: some Scene {
        WindowGroup {
            GeometryReader { geometry in
                if viewModel.isInitialized {
                    ZStack {
                        WorkView(viewModel: viewModel.workViewModel, showLogs: $viewModel.showLogs, showDiff: $viewModel.showDiff)

                        if viewModel.showLogs {
                            LogListView(showLogs: $viewModel.showLogs, viewModel: viewModel.logListViewModel)
                        }

                        if viewModel.showDiff {
                            DiffView(showDiff: $viewModel.showDiff, viewModel: viewModel.diffViewModel)
                        }
                    }
                    .offset(y: CGFloat(UserDefaults.standard.double(forKey: "SAFE_AREA_TOP")))
                    .rotationEffect(Angle(degrees: 180))
                    .statusBarHidden()
                    .preferredColorScheme(.dark)
                } else {
                    ProgressView()
                        .scaleEffect(2)
                        .onAppear {
                            let screenHeight = geometry.size.height
                            let screenWidth = geometry.size.width
                            let safeTop = geometry.safeAreaInsets.top
                            let safeBottom = geometry.safeAreaInsets.bottom

                            UserDefaults.standard.set(screenHeight, forKey: "SCREEN_HEIGHT")
                            UserDefaults.standard.set(screenWidth, forKey: "SCREEN_WIDTH")
                            UserDefaults.standard.set(safeTop, forKey: "SAFE_AREA_TOP")
                            UserDefaults.standard.set(safeBottom, forKey: "SAFE_AREA_BOTTOM")

                            log("📱 Screen: \(Int(screenWidth))x\(Int(screenHeight)), top safe area: \(Int(safeTop)), bottom safe area: \(Int(safeBottom))")

                            #if MANUAL_TESTING && IS_TEST
                            log("🧪 Flags: IS_TEST=true MANUAL_TESTING=true")
                            #elseif IS_TEST && !MANUAL_TESTING
                            log("🤖 Flags: IS_TEST=true MANUAL_TESTING=false")
                            #elseif !IS_TEST && !MANUAL_TESTING
                            log("🚀 Flags: IS_TEST=false MANUAL_TESTING=false")
                            #else
                            error("Unexpected flag combination")
                            #endif

                            viewModel.isInitialized = true
                        }
                }
            }
        }
    }
}
