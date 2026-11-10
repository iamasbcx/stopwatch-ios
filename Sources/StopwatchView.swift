import Foundation
import SwiftUI

struct StopwatchView: View {
    let onUnlock: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var input = ""
    @State private var remaining = 0
    @State private var isRunning = false
    @State private var deadline: Date?
    @State private var pausedInterval: TimeInterval?
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
                TextField("Seconds", text: $input)
                    .keyboardType(.numberPad)
                    .focused($isInputFocused)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .multilineTextAlignment(.center)
                    .disabled(isRunning || remaining > 0)
                    .onChange(of: input) { _, value in
                        input = value.filter(\.isNumber)
                        errorMessage = nil
                    }
                if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
                HStack(spacing: 12) {
                    Button(isRunning ? "Pause" : (remaining > 0 ? "Resume" : "Start")) { startOrPause() }
                        .buttonStyle(.borderedProminent).tint(.cyan)
                    Button("Reset") { reset() }.buttonStyle(.bordered)
                }
                Spacer()
                Text("Lap Timer").font(.caption).foregroundStyle(.secondary).padding(.bottom, 12)
            }
            .padding(24)
        }
        .onReceive(timer) { _ in
            updateRemaining()
        }
        .onChange(of: scenePhase) { _, phase in
            // 后台期间系统可能暂停 Timer，回到前台时按绝对截止时间补齐倒计时。
            if phase == .active {
                updateRemaining()
            }
        }
        .onTapGesture { isInputFocused = false }
    }

    private var timeText: String {
        String(format: "%02d:%02d:%02d", remaining / 3600, (remaining % 3600) / 60, remaining % 60)
    }

    private func startOrPause() {
        if isRunning {
            updateRemaining()
            if let deadline {
                pausedInterval = max(0, deadline.timeIntervalSinceNow)
            }
            isRunning = false
            deadline = nil
            return
        }
        guard let value = Int(input), value > 0 else {
            errorMessage = "Enter a positive whole number."
            return
        }
        if remaining == 0 && pausedInterval == nil && input == "5201314" {
            isInputFocused = false
            onUnlock()
            return
        }
        // remaining 大于零表示暂停状态，恢复时沿用剩余秒数，避免重新从输入值开始。
        let interval = pausedInterval ?? (remaining == 0 ? TimeInterval(value) : TimeInterval(remaining))
        guard interval > 0 else {
            remaining = 0
            return
        }
        pausedInterval = nil
        deadline = Date().addingTimeInterval(interval)
        remaining = Int(ceil(interval))
        isRunning = true
        isInputFocused = false
    }

    private func updateRemaining() {
        guard isRunning, let deadline else { return }
        let interval = deadline.timeIntervalSinceNow
        guard interval > 0 else {
            remaining = 0
            isRunning = false
            self.deadline = nil
            pausedInterval = nil
            return
        }
        // 向上取整，让显示值在完整的一秒结束前保持不变，同时避免零点多运行一秒。
        remaining = Int(ceil(interval))
    }

    private func reset() {
        isRunning = false
        deadline = nil
        pausedInterval = nil
        remaining = 0
        errorMessage = nil
    }
}
