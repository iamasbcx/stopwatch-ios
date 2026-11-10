import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 解锁后的 TRON 工作区；查询与编辑状态由主线程状态对象统一持久化。
struct TronManagerView: View {
    @StateObject private var state = StopwatchState()
    @Environment(\.scenePhase) private var scenePhase
    @State private var activeSheet: ManagerSheet?
    @State private var isExporting = false
    @State private var exportText = ""
    @State private var actionMessage: String?
    @State private var showingRestoreConfirmation = false

    var body: some View {
        NavigationStack {
            exportingContent
                .navigationTitle("TRON 管理器")
                .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: $activeSheet) { sheet in
            sheetContent(sheet)
        }
    }

    // 用独立表达式隔离导出、生命周期与布局，减少 SwiftUI 类型检查的复杂度。
    private var exportingContent: some View {
        observedContent
            .fileExporter(isPresented: $isExporting,
                          document: TransactionTextDocument(text: exportText),
                          contentType: .plainText,
                          defaultFilename: "TRON-交易记录") { result in
                switch result {
                case .success:
                    actionMessage = "查询结果已导出为 UTF-8 文本。"
                case .failure(let error):
                    actionMessage = "导出失败：\(TronErrorMessage.describe(error))"
                }
            }
            .confirmationDialog("用当前交易记录替换编辑内容？", isPresented: $showingRestoreConfirmation,
                                titleVisibility: .visible) {
                Button("恢复查询结果", role: .destructive) { state.restoreQueryOutput() }
                Button("取消", role: .cancel) { }
            }
    }

    private var observedContent: some View {
        pageContent
            .onAppear { state.setSceneActive(scenePhase == .active) }
            .onDisappear { state.setSceneActive(false) }
            .onChange(of: scenePhase) { _, phase in
                state.setSceneActive(phase == .active)
            }
    }

    private var pageContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                addressSection
                balanceSection
                queryControls
                actionGrid
                statusSection
                resultEditor
                recordSection
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    @ViewBuilder
    private func sheetContent(_ sheet: ManagerSheet) -> some View {
        switch sheet {
        case .permissions:
            LapDetailsView(tag: state.lapTag.trimmingCharacters(in: .whitespacesAndNewlines))
        case .transfer:
            SplitView()
        case .conversion:
            TimeSettingsView()
        }
    }

    private var addressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("查询地址").font(.headline)
            TextField("输入 T 开头的 TRON 地址", text: $state.lapTag)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .submitLabel(.search)
                .onSubmit { state.start() }
            Text("地址和查询结果自动保存，下次打开可继续编辑。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var balanceSection: some View {
        GroupBox {
            if let metrics = state.metrics {
                balanceGrid(metrics)
            } else {
                Text("查询地址后显示 TRX、USDT 余额及可用资源。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("刷新余额") { state.refreshMetrics() }
                .buttonStyle(.bordered)
                .disabled(state.isLoading || state.lapTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } label: {
            Label("账户余额与资源", systemImage: "chart.bar.xaxis")
        }
    }

    private func balanceGrid(_ metrics: StopwatchMetrics) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            MetricCell(title: "TRX", value: decimalText(metrics.primary))
            MetricCell(title: "USDT", value: decimalText(metrics.secondary))
            MetricCell(title: "能量（可用 / 总额）", value: resourceText(used: metrics.focusUsed, limit: metrics.focusLimit))
            MetricCell(title: "带宽（可用 / 总额）", value: resourceText(used: metrics.rangeUsed, limit: metrics.rangeLimit))
        }
    }

    private var queryControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("查询 TRX") { state.query(.lap) }
                Button("查询 TRC20") { state.query(.split) }
                Button("下一页") { state.start(reset: false) }
                    .disabled(state.cursor == nil)
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.isLoading)
            Text("当前：\(state.kind.rawValue) · TRC20 查询包含 USDT 及其他代币")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("监控新交易", isOn: $state.autoLap)
            Text("前台每 10 秒刷新；手动编辑的查询结果不会被监控覆盖。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // 功能按钮直接置于页面，避免导航栏工具项在容器中不显示而失去入口。
    private var actionGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            Button { activeSheet = .permissions } label: {
                Label("账户权限", systemImage: "lock.shield")
            }
            Button { activeSheet = .transfer } label: {
                Label("转账", systemImage: "arrow.up.right")
            }
            Button { activeSheet = .conversion } label: {
                Label("地址转换", systemImage: "key")
            }
            Button(action: copyOutput) { Label("复制结果", systemImage: "doc.on.doc") }
                .disabled(state.resultText.isEmpty)
            Button(action: exportOutput) { Label("导出 TXT", systemImage: "square.and.arrow.up") }
                .disabled(state.resultText.isEmpty)
            ShareLink(item: state.resultText) { Label("分享", systemImage: "square.and.arrow.up.on.square") }
                .disabled(state.resultText.isEmpty)
        }
        .buttonStyle(.bordered)
        .font(.subheadline)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.isLoading { ProgressView("正在查询链上数据…") }
            if let message = state.message { Text(message).foregroundStyle(.secondary) }
            if let message = state.monitorMessage { Text(message).foregroundStyle(.orange) }
            if let actionMessage { Text(actionMessage).foregroundStyle(.secondary) }
        }
        .font(.footnote)
    }

    private var resultEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("查询结果（可编辑）").font(.headline)
                Spacer()
                Button("恢复查询结果") { showingRestoreConfirmation = true }
                    .font(.caption)
                    .disabled(state.records.isEmpty)
            }
            TextEditor(text: $state.resultText)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 220, maxHeight: 380)
                .padding(6)
                .scrollContentBackground(.hidden)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            Text("支持选择、修改、复制、粘贴；导出与分享以编辑框中的文本为准。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var recordSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("链上交易记录").font(.headline)
            if state.records.isEmpty {
                ContentUnavailableView("暂无交易记录", systemImage: "tray",
                                       description: Text("输入 TRON 地址后，点击查询 TRX 或查询 TRC20。"))
            } else {
                // 同一链上交易可能包含多个 TRC20 事件，不能仅用交易 ID 作为视图标识。
                ForEach(Array(state.records.enumerated()), id: \.offset) { item in
                    TransactionCard(record: item.element, number: item.offset + 1,
                                    address: state.lapTag.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
    }

    private func copyOutput() {
        UIPasteboard.general.string = state.resultText
        actionMessage = "已复制编辑框中的查询结果。"
    }

    private func exportOutput() {
        // 固定导出快照，文件选择器打开期间的刷新不会改变此次导出内容。
        exportText = state.resultText
        isExporting = true
    }

    private func resourceText(used: Int64, limit: Int64) -> String {
        limit == 0 ? "0 / --" : "\(max(0, limit - used)) / \(limit)"
    }
}

private enum ManagerSheet: String, Identifiable {
    case permissions, transfer, conversion
    var id: String { rawValue }
}

/// 导出编辑器内容为 UTF-8 文本，由系统文件选择器管理目标文件的写入权限。
private struct TransactionTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    let text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

private struct MetricCell: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TransactionCard: View {
    let record: LapRecord
    let number: Int
    let address: String
    private var isIncoming: Bool { record.to == address }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("#\(number) · \(isIncoming ? "收入" : "支出")")
                Spacer()
                Text("\(isIncoming ? "+" : "−")\(decimalText(record.amount)) \(record.label)")
                    .foregroundStyle(isIncoming ? Color.green : Color.red)
            }
            .font(.subheadline.weight(.semibold))
            Text("交易 ID：\(record.id)").foregroundStyle(.purple)
            Text("发送方：\(record.from)").foregroundStyle(.secondary)
            Text("接收方：\(record.to)").foregroundStyle(.blue)
            Text("时间：\(record.timeText)")
        }
        .font(.caption)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

private func decimalText(_ value: Decimal) -> String {
    // 保留 Decimal 精度，不把小于百万分之一的 TRC20 转账显示为零。
    NSDecimalNumber(decimal: value).stringValue
}
