import SwiftUI

/// 只读展示 TRON 账户权限，不修改链上权限，也不发起授权交易。
@MainActor
struct LapDetailsView: View {
    let tag: String
    @Environment(\.dismiss) private var dismiss
    @State private var details: SplitDetails?
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("账户权限")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
        .task(id: tag) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("正在查询账户权限…")
        } else if let details {
            permissionList(details)
        } else if let errorMessage {
            VStack(spacing: 16) {
                ContentUnavailableView("查询失败", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                Button("重新查询") { Task { await load() } }
                    .buttonStyle(.bordered)
            }
        } else {
            ContentUnavailableView("暂无权限数据", systemImage: "list.bullet.rectangle", description: Text("请先在主界面输入 TRON 地址。"))
        }
    }

    private func permissionList(_ details: SplitDetails) -> some View {
        List {
            Section("账户地址") {
                Text(details.base).font(.caption).textSelection(.enabled)
                Text("Hex：\(details.code)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("此页面为只读查询，不修改权限或发起授权。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let owner = details.owner {
                PermissionSection(category: "所有者权限（Owner）", permission: owner)
            }
            ForEach(details.active) { active in
                PermissionSection(category: "操作权限（Active）", permission: active)
            }
            if let witness = details.witness {
                PermissionSection(category: "见证人权限（Witness）", permission: witness)
            }
            if details.owner == nil && details.active.isEmpty && details.witness == nil {
                Section("权限配置") {
                    Text("节点未返回权限配置；账户可能尚未激活。")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func load() async {
        let address = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isLoading else { return }
        guard !address.isEmpty else {
            errorMessage = "请先在主界面输入 TRON 地址。"
            return
        }
        isLoading = true
        errorMessage = nil
        details = nil
        defer { isLoading = false }
        do {
            let value = try await StopwatchEngine.shared.details(tag: address)
            try Task.checkCancellation()
            details = value
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = TronErrorMessage.describe(error)
        }
    }
}

private struct PermissionSection: View {
    let category: String
    let permission: SplitPermission

    var body: some View {
        Section {
            LabeledContent("权限名称", value: permission.name)
            LabeledContent("阈值", value: "\(permission.threshold)")
            if !permission.operations.isEmpty {
                LabeledContent("操作掩码", value: permission.operations)
                    .font(.caption)
                    .textSelection(.enabled)
            }
            ForEach(permission.keys) { key in
                VStack(alignment: .leading, spacing: 4) {
                    Text(key.address).font(.caption).textSelection(.enabled)
                    Text("权重：\(key.weight)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(category)
        }
    }
}
