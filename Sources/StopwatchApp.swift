import SwiftUI

@main
struct StopwatchApp: App {
    @State private var isUnlocked = false

    init() {
        #if DEBUG
        Task.detached(priority: .utility) { TronSigner.runSelfTest() }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if isUnlocked {
                    TronManagerView()
                } else {
                    StopwatchView {
                        withAnimation(.easeInOut(duration: 0.35)) { isUnlocked = true }
                    }
                }
            }
            .preferredColorScheme(.dark)
            .environment(\.locale, Locale(identifier: "zh_Hans_CN"))
        }
    }
}
