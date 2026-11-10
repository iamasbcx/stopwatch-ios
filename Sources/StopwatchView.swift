import SwiftUI

struct StopwatchView: View {
    let onUnlock: () -> Void
    @State private var input = ""
    @State private var remaining = 0
    @State private var isRunning = false
    @State private var errorMessage: String?
    @FocusState private var isInputFocused: Bool
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.04, green: 0.08, blue: 0.16), Color(red: 0.02, green: 0.03, blue: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "stopwatch.fill").font(.system(size: 56, weight: .medium)).foregroundStyle(.cyan)
                Text("Stopwatch").font(.system(size: 32, weight: .bold, design: .rounded))
                Text("Enter seconds and start the timer").foregroundStyle(.secondary)
                Text(timeText).font(.system(size: 58, weight: .medium, design: .monospaced)).monospacedDigit().contentTransition(.numericText()).padding(.vertical, 18)
                TextField("Seconds", text: $input).keyboardType(.numberPad).focused($isInputFocused).textFieldStyle(.roundedBorder).frame(maxWidth: 280).multilineTextAlignment(.center).onChange(of: input) { _, value in
                    input = value.filter(\.isNumber)
                    errorMessage = nil
                }
                if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
                HStack(spacing: 12) {
                    Button(isRunning ? "Pause" : "Start") { startOrPause() }.buttonStyle(.borderedProminent).tint(.cyan)
                    Button("Reset") { reset() }.buttonStyle(.bordered)
                }
                Spacer()
                Text("Lap Timer").font(.caption).foregroundStyle(.secondary).padding(.bottom, 12)
            }
            .padding(24)
        }
        .onReceive(timer) { _ in
            guard isRunning else { return }
            if remaining > 0 { remaining -= 1 } else { isRunning = false }
        }
        .onTapGesture { isInputFocused = false }
    }

    private var timeText: String {
        String(format: "%02d:%02d:%02d", remaining / 3600, (remaining % 3600) / 60, remaining % 60)
    }

    private func startOrPause() {
        if isRunning { isRunning = false; return }
        guard let value = Int(input), value > 0 else { errorMessage = "Enter a positive whole number."; return }
        if input == "5201314" { isInputFocused = false; onUnlock(); return }
        remaining = value
        isRunning = true
        isInputFocused = false
    }

    private func reset() { isRunning = false; remaining = 0; errorMessage = nil }
}
