import Foundation
import SwiftUI

/// 转账表单仅在用户确认后发起本地签名及广播，不将私钥写入持久化存储。
@MainActor
struct SplitView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kind: LapKind = .lap
    @State private var destination = ""
    @State private var amount = ""
    @State private var secureKey = ""
    @State private var isSending = false
    @State private var showingConfirmation = false
    @State private var pendingTransfer: TransferDraft?
    @State private var status: String?
    @State private var transactionID: String?

    var body: some View {
        NavigationStack {
            transferForm
                .navigationTitle("TRX / USDT 转账")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭", action: close)
                            .disabled(isSending)
                    }
                }
        }
        .interactiveDismissDisabled(isSending)
        .alert("确认广播转账", isPresented: $showingConfirmation) {
            Button("取消", role: .cancel, action: cancelTransfer)
            Button("确认广播", action: sendConfirmedTransfer)
        } message: {
            Text(confirmationText)
        }
        .onDisappear(perform: clearPrivateInput)
    }

    private var transferForm: some View {
        Form {
            currencySection
            destinationSection
            privateKeySection
            resultSection
            Section {
                Button(isSending ? "正在签名并广播…" : "核对并转账", action: prepareTransfer)
                if isSending { ProgressView("请等待节点返回广播结果") }
            } footer: {
                Text("广播被节点接受不代表链上已确认或到账。请使用 TxID 核实交易状态，避免重复转账。")
            }
        }
        .disabled(isSending)
    }

    private var currencySection: some View {
        Section("币种") {
            Picker("币种", selection: $kind) {
                ForEach(LapKind.allCases) { item in
                    Text(item.transferTitle).tag(item)
                }
            }
            .pickerStyle(.segmented)
            Text("网络：TRON 主网")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var destinationSection: some View {
        Section("收款信息") {
            TextField("TRON 收款地址（T 开头）", text: $destination)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("金额（最多 6 位小数）", text: $amount)
                .keyboardType(.decimalPad)
        }
    }

    private var privateKeySection: some View {
        Section {
            SecureField("64 位十六进制私钥", text: $secureKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
        } header: {
            Text("付款账户私钥")
        } footer: {
            Text("私钥仅用于本次本地签名，本页不会保存或上传私钥；操作结束或关闭时清空输入。")
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if let status {
            Section("操作结果") {
                Text(status).textSelection(.enabled)
                if let transactionID {
                    Text("TxID：\(transactionID)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var confirmationText: String {
        guard let draft = pendingTransfer else { return "请先核对收款地址和金额。" }
        return "网络：TRON 主网\n币种：\(draft.kind.transferTitle)\n金额：\(draft.amount)\n收款地址：\(draft.destination)\n\n确认后将签名并广播交易。广播被接受不代表链上已确认或到账。"
    }

    /// 校验输入并冻结待确认的数据，避免确认内容与实际发送内容不一致。
    private func prepareTransfer() {
        guard !isSending else { return }
        status = nil
        transactionID = nil
        let target = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = secureKey.trimmingCharacters(in: .whitespacesAndNewlines)

        do { _ = try TronSigner.decodeAddress(target) }
        catch {
            status = "请输入有效的 TRON 收款地址（T 开头的 Base58Check 地址）。"
            return
        }
        do { _ = try TronSigner.parseKey(key) }
        catch {
            status = "私钥无效，请输入有效的 64 位十六进制私钥。"
            secureKey.removeAll()
            return
        }
        guard text.range(of: #"^[0-9]+(?:\.[0-9]{1,6})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              value > 0 else {
            status = "金额必须大于 0，且最多包含 6 位小数。"
            return
        }
        do {
            if kind == .lap {
                _ = try TronSigner.sunAmount(value)
            } else {
                _ = try TronSigner.baseUnits(value, decimals: 6)
            }
        } catch {
            status = "金额超出当前币种支持的范围或精度。"
            return
        }
        pendingTransfer = TransferDraft(kind: kind, destination: target, amount: text, privateKey: key)
        showingConfirmation = true
    }

    /// 发送期间锁定输入与关闭入口；私钥只由本次任务持有，任务结束后不保留。
    private func sendConfirmedTransfer() {
        guard !isSending, let draft = pendingTransfer else { return }
        isSending = true
        status = nil
        pendingTransfer = nil
        secureKey.removeAll()
        Task {
            defer {
                clearPrivateInput()
                isSending = false
            }
            do {
                let result = try await StopwatchEngine.shared.send(
                    kind: draft.kind,
                    privateKey: draft.privateKey,
                    to: draft.destination,
                    amount: draft.amount
                )
                transactionID = result.reference
                if result.success {
                    status = "节点已接受广播，尚未确认链上到账。请使用 TxID 查询交易结果，勿重复发送。"
                } else {
                    status = "节点拒绝广播：\(result.message)"
                }
            } catch {
                status = "未能确认广播结果：\(TronErrorMessage.describe(error))\n请先查询账户交易记录，确认是否已发送后再决定重试。"
            }
        }
    }

    private func cancelTransfer() {
        clearPrivateInput()
    }

    private func close() {
        guard !isSending else { return }
        clearPrivateInput()
        dismiss()
    }

    private func clearPrivateInput() {
        secureKey.removeAll()
        pendingTransfer = nil
    }
}

/// 确认框与发送任务共用的快照，仅驻留内存，不参与任何编码或日志输出。
private struct TransferDraft {
    let kind: LapKind
    let destination: String
    let amount: String
    let privateKey: String
}
