import SwiftUI
import UIKit

struct LapView: View {
    @StateObject private var state = StopwatchState()
    @State private var showingDetails = false
    @State private var showingSplit = false
    @State private var showingSettings = false
    @State private var resultText = UserDefaults.standard.string(forKey: "stopwatch.resultText") ?? ""

    var body: some View {
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
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showingDetails = true } label: { Label("Lap Details", systemImage: "list.bullet.rectangle") }
                        Button { showingSplit = true } label: { Label("Split", systemImage: "arrow.up.right") }
                        Button { showingSettings = true } label: { Label("Time Settings", systemImage: "gearshape") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingDetails) { LapDetailsView(tag: state.lapTag) }
            .sheet(isPresented: $showingSplit) { SplitView() }
            .sheet(isPresented: $showingSettings) { TimeSettingsView() }
            .onChange(of: resultText) { _, value in\n                UserDefaults.standard.set(value, forKey: "stopwatch.resultText")\n            }\n            .onChange(of: state.records) { _, records in
                resultText = records.map {
                    "Lap: \($0.id)\nFrom: \($0.from)\nTo: \($0.to)\nValue: \(decimalText($0.amount)) \($0.label)\nTime: \($0.timeText)"
                }.joined(separator: "\n\n")
            }
        }
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
            .onChange(of: state.kind) { _, _ in state.resetCursor() }

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
            if state.isLoading { ProgressView("Updating lap…").frame(maxWidth: .infinity, alignment: .leading) }
            if let message = state.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private var recordSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Lap History").font(.headline)
                Spacer()
                if !state.records.isEmpty {
                    ShareLink(item: exportText) { Image(systemName: "square.and.arrow.up") }
                    Button { UIPasteboard.general.string = exportText } label: { Image(systemName: "doc.on.doc") }
                }
            }
            if state.records.isEmpty {
                ContentUnavailableView("No Laps", systemImage: "tray", description: Text("Enter a lap tag and press Start"))
            } else {
                ForEach(state.records) { record in LapCard(record: record, tag: state.lapTag) }
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

    private var exportText: String {
        state.records.map { "Lap: \($0.id)\nFrom: \($0.from)\nTo: \($0.to)\nValue: \(decimalText($0.amount)) \($0.label)\nTime: \($0.timeText)" }.joined(separator: "\n\n")
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

