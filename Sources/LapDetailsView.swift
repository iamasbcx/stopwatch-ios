import SwiftUI

struct LapDetailsView: View {
    let tag: String
    @Environment(\.dismiss) private var dismiss
    @State private var details: SplitDetails?
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading lap details…")
                } else if let details {
                    List {
                        Section("Lap Tag") {
                            Text(details.base).font(.caption).textSelection(.enabled)
                            Text(details.code).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let owner = details.owner { PermissionSection(permission: owner) }
                        ForEach(details.active) { active in PermissionSection(permission: active) }
                        if let witness = details.witness { PermissionSection(permission: witness) }
                    }
                } else if let errorMessage {
                    ContentUnavailableView("Load Failed", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                } else {
                    ContentUnavailableView("No Details", systemImage: "list.bullet.rectangle", description: Text("Enter a lap tag first."))
                }
            }
            .navigationTitle("Lap Details")
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
        }
        .task { await load() }
    }

    private func load() async {
        guard !tag.isEmpty else { errorMessage = "Enter a lap tag on the main screen first."; return }
        isLoading = true
        do { details = try await StopwatchEngine.shared.details(tag: tag) }
        catch { errorMessage = error.localizedDescription }
        isLoading = false
    }
}

private struct PermissionSection: View {
    let permission: SplitPermission

    var body: some View {
        Section(permission.name) {
            LabeledContent("Threshold", value: "\(permission.threshold)")
            if !permission.operations.isEmpty { LabeledContent("Operation Mask", value: permission.operations) }
            ForEach(permission.keys) { key in
                HStack {
                    Text(key.address).font(.caption).lineLimit(1)
                    Spacer()
                    Text("Weight \(key.weight)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
