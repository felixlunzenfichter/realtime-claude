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

@Observable
class ViewModel {
    var isInitialized: Bool = false
    var showLogs: Bool = false
    var workViewModel = WorkViewModel()
    var logListViewModel = LogListViewModel()
}

@main
struct RealtimeClaudeApp: App {
    @State private var viewModel = ViewModel()

    var body: some Scene {
        WindowGroup {
            GeometryReader { geometry in
                if viewModel.isInitialized {
                    ZStack {
                        WorkView(viewModel: viewModel.workViewModel, showLogs: $viewModel.showLogs)

                        if viewModel.showLogs {
                            LogListView(showLogs: $viewModel.showLogs, viewModel: viewModel.logListViewModel)
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
                            let safeTop = geometry.safeAreaInsets.top
                            let safeBottom = geometry.safeAreaInsets.bottom

                            UserDefaults.standard.set(screenHeight, forKey: "SCREEN_HEIGHT")
                            UserDefaults.standard.set(safeTop, forKey: "SAFE_AREA_TOP")
                            UserDefaults.standard.set(safeBottom, forKey: "SAFE_AREA_BOTTOM")

                            log("📱 Screen height: \(Int(screenHeight)), top safe area: \(Int(safeTop)), bottom safe area: \(Int(safeBottom))")

                            viewModel.isInitialized = true
                        }
                }
            }
        }
    }
}
