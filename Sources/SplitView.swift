import SwiftUI

struct SplitView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kind: LapKind = .lap
    @State private var destination = ""
    @State private var amount = ""
    @State private var secureKey = ""
    @State private var isSending = false
    @State private var status: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Split Type") {
                    Picker("Type", selection: $kind) { ForEach(LapKind.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented)
                }
                Section("Destination") {
                    TextField("Destination tag", text: $destination).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Amount", text: $amount).keyboardType(.decimalPad)
                }
                Section("Secure Key") {
                    SecureField("64 hexadecimal characters", text: $secureKey)
                    Text("The key stays in memory and is cleared after the action.").font(.footnote).foregroundStyle(.secondary)
                }
                if let status { Section { Text(status).foregroundStyle(.secondary) } }
                Section { Button(isSending ? "Working…" : "Send") { send() }.disabled(isSending) }
            }
            .navigationTitle("Split")
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
        }
    }

    private func send() {
        isSending = true
        status = nil
        Task {
            do {
                let result = try await StopwatchEngine.shared.send(kind: kind, privateKey: secureKey, to: destination, amount: amount)
                status = result.success ? "Completed: \(result.reference ?? "")" : result.message
            } catch { status = error.localizedDescription }
            secureKey.removeAll()
            isSending = false
        }
    }
}
