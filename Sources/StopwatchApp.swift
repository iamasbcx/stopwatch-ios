import SwiftUI

@main
struct StopwatchApp: App {
    @State private var isUnlocked = false

    var body: some Scene {
        WindowGroup {
            Group {
                if isUnlocked {
                    LapView()
                } else {
                    StopwatchView {
                        withAnimation(.easeInOut(duration: 0.35)) { isUnlocked = true }
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}
