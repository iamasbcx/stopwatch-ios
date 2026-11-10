import SwiftUI

struct TimeSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var secureKey = ""
    @State private var result: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Time Key") {
                    SecureField("64 hexadecimal characters", text: $secureKey)
                    Button("Convert") { convert() }
                }
                if let result { Section("Lap Tag") { Text(result).textSelection(.enabled) } }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.secondary) } }
            }
            .navigationTitle("Time Settings")
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
        }
        .onDisappear { secureKey.removeAll() }
    }

    private func convert() {
        do { result = try StopwatchEngine.shared.deriveTime(privateKey: secureKey); errorMessage = nil }
        catch { result = nil; errorMessage = error.localizedDescription }
        secureKey.removeAll()
    }
}
