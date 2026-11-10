import SwiftUI
import UIKit

/// 私钥转地址在本机执行；仅地址结果可复制，私钥输入在转换或关闭后清空。
@MainActor
struct TimeSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var secureKey = ""
    @State private var result: String?
    @State private var errorMessage: String?
    @State private var isConverting = false

    var body: some View {
        NavigationStack {
            conversionForm
                .navigationTitle("私钥转地址")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭") {
                            secureKey.removeAll()
                            dismiss()
                        }
                        .disabled(isConverting)
                    }
                }
        }
        .interactiveDismissDisabled(isConverting)
        .onDisappear { secureKey.removeAll() }
    }

    private var conversionForm: some View {
        Form {
            inputSection
            resultSection
            if let errorMessage {
                Section("转换失败") {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
    }

    private var inputSection: some View {
        Section {
            SecureField("64 位十六进制私钥", text: $secureKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
                .disabled(isConverting)
            Button(isConverting ? "正在转换…" : "转换为 TRON 地址", action: convert)
                .disabled(isConverting || secureKey.isEmpty)
            if isConverting { ProgressView() }
        } header: {
            Text("私钥")
        } footer: {
            Text("仅在本机计算，不发起网络请求；私钥不会保存，转换结束或关闭时清空输入。")
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if let result {
            Section("TRON 地址") {
                Text(result)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Button("复制地址") { UIPasteboard.general.string = result }
            }
        }
    }

    /// 将耗时的椭圆曲线计算放到后台任务，仅将地址结果返回主线程更新界面。
    private func convert() {
        guard !isConverting else { return }
        let key = secureKey.trimmingCharacters(in: .whitespacesAndNewlines)
        result = nil
        errorMessage = nil
        secureKey.removeAll()
        do { _ = try TronSigner.parseKey(key) }
        catch {
            errorMessage = "私钥无效，请输入有效的 64 位十六进制私钥。"
            return
        }
        isConverting = true
        Task {
            defer {
                secureKey.removeAll()
                isConverting = false
            }
            do {
                result = try await Task.detached(priority: .userInitiated) {
                    try TronSigner.address(privateKeyHex: key)
                }.value
            } catch {
                errorMessage = "无法转换地址：\(TronErrorMessage.describe(error))"
            }
        }
    }
}
