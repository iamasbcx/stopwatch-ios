import SwiftUI
import UIKit

struct LapView: View {
    @StateObject private var state = StopwatchState()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingDetails = false
    @State private var showingSplit = false
    @State private var showingSettings = false
    @State private var resultText = UserDefaults.standard.string(forKey: "stopwatch.resultText") ?? ""
    // 记录上一次由查询自动生成的文本，用于区分系统刷新和用户手动编辑。
    @State private var generatedResultText = ""

    var body: some View {
        navigationContent
            .sheet(isPresented: $showingDetails) {
                detailsSheet
            }
            .sheet(isPresented: $showingSplit) {
                SplitView()
            }
            .sheet(isPresented: $showingSettings) {
                TimeSettingsView()
            }
    }

    private var navigationContent: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    tagSection
                    metricsSection
                    controlSection
                    resultEditor
                    recordSection
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Lap Timer")
            .toolbar {
                navigationToolbar
            }
            .onChange(of: resultText) { _, value in
                UserDefaults.standard.set(value, forKey: "stopwatch.resultText")
            }
            .onChange(of: state.lapTag) { _, _ in
                // 标签变更后旧查询结果不再属于当前账户，清除展示文本并允许新结果首次填充。
                clearGeneratedResult()
            }
            .onChange(of: state.kind) { _, _ in
                // 模式切换后记录语义改变，避免把上一模式的文本带到当前列表。
                clearGeneratedResult()
            }
            .onChange(of: scenePhase) { _, phase in
                state.setSceneActive(phase == .active)
            }
            .onChange(of: state.records) { _, records in
                handleRecordsChange(records)
            }
        }
    }

    private var detailsSheet: some View {
        LapDetailsView(tag: state.lapTag.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            actionsMenu
        }
    }

    private var actionsMenu: some View {
        Menu {
            Button { showingDetails = true } label: { Label("Lap Details", systemImage: "list.bullet.rectangle") }
            Button { showingSplit = true } label: { Label("Split", systemImage: "arrow.up.right") }
            Button { showingSettings = true } label: { Label("Time Settings", systemImage: "gearshape") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    /// 清理当前标签或模式失效后的自动结果，允许下一次查询重新填充。
    private func clearGeneratedResult() {
        resultText = ""
        generatedResultText = ""
    }

    /// 根据记录更新结果编辑器，同时保留用户已经手动修改的内容。
    private func handleRecordsChange(_ records: [LapRecord]) {
        // 记录清空时只清除仍等于自动生成文本的内容，保留用户手动编辑。
        if records.isEmpty {
            if resultText == generatedResultText {
                clearGeneratedResult()
            }
            return
        }

        let generated = records.map { record in
            "Lap: \(record.id)\nFrom: \(record.from)\nTo: \(record.to)\nValue: \(decimalText(record.amount)) \(record.label)\nTime: \(record.timeText)"
        }.joined(separator: "\n\n")
        // 只有编辑器为空或仍是上一次自动生成值时才更新，避免覆盖用户编辑。
        guard resultText == generatedResultText || (resultText.isEmpty && generatedResultText.isEmpty) else { return }
        resultText = generated
        generatedResultText = generated
    }

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lap Tag").font(.headline)
            TextField("Enter a tag", text: $state.lapTag)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .onSubmit { state.start() }
            if !state.lapTag.isEmpty {
                Label("Saved locally for the next session", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var metricsSection: some View {
        GroupBox {
            if let metrics = state.metrics {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    MetricCell(title: "Lap", value: decimalText(metrics.primary))
                    MetricCell(title: "Split", value: decimalText(metrics.secondary))
                    MetricCell(title: "Focus", value: resourceText(used: metrics.focusUsed, limit: metrics.focusLimit))
                    MetricCell(title: "Range", value: resourceText(used: metrics.rangeUsed, limit: metrics.rangeLimit))
                }
            } else {
                HStack {
                    Image(systemName: "chart.bar.xaxis")
                    Text("Start a lap to show timing metrics")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { state.refreshMetrics() }
                        .buttonStyle(.bordered)
                }
            }
        } label: {
            Label("Stopwatch Metrics", systemImage: "gauge.with.dots.needle.67percent")
        }
    }

    private var controlSection: some View {
        VStack(spacing: 12) {
            Picker("Mode", selection: $state.kind) {
                ForEach(LapKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
            }
            .pickerStyle(.segmented)

            HStack {
                Button { state.start() } label: { Label("Start", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isLoading)
                Button { state.start(reset: false) } label: { Label("Next Lap", systemImage: "chevron.down") }
                    .buttonStyle(.bordered)
                    .disabled(state.isLoading || state.cursor == nil)
                Spacer()
                Toggle("Auto Lap", isOn: $state.autoLap)
                    .toggleStyle(.switch)
                    .font(.subheadline)
            }
            if state.isLoading {
                ProgressView("Updating lap…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let message = state.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var resultEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Result Text").font(.headline)
                Spacer()
                Button {
                    UIPasteboard.general.string = resultText
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(resultText.isEmpty)
            }
            TextEditor(text: $resultText)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 150, maxHeight: 280)
                .padding(6)
                .scrollContentBackground(.hidden)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if resultText.isEmpty {
                        Text("Query results appear here. Select, edit, copy, or share any text.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private var recordSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Lap History").font(.headline)
                Spacer()
                if !state.records.isEmpty {
                    ShareLink(item: resultText) { Image(systemName: "square.and.arrow.up") }
                    Button { UIPasteboard.general.string = resultText } label: { Image(systemName: "doc.on.doc") }
                }
            }
            if state.records.isEmpty {
                ContentUnavailableView("No Laps", systemImage: "tray", description: Text("Enter a lap tag and press Start"))
            } else {
                ForEach(state.records) { record in
                    LapCard(record: record, tag: state.lapTag.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
    }

    private func resourceText(used: Int64, limit: Int64) -> String {
        limit == 0 ? "\(used) / --" : "\(max(0, limit - used)) / \(limit)"
    }
}

private struct MetricCell: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LapCard: View {
    let record: LapRecord
    let tag: String
    private var isIncoming: Bool { record.to.caseInsensitiveCompare(tag) == .orderedSame }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(isIncoming ? "IN" : "OUT")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(isIncoming ? Color.green : Color.red, in: Capsule())
                Text("\(decimalText(record.amount)) \(record.label)")
                    .font(.headline)
                    .foregroundStyle(isIncoming ? .green : .red)
                Spacer()
                Text(record.timeText).font(.caption).foregroundStyle(.secondary)
            }
            Text("From  \(record.from)").font(.caption).lineLimit(1)
            Text("To    \(record.to)").font(.caption).lineLimit(1)
            Text("Lap   \(record.id)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }
}

private func decimalText(_ value: Decimal) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 6
    return formatter.string(from: value as NSDecimalNumber) ?? "0"
}
