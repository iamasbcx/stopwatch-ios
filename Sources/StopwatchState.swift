import Foundation
import SwiftUI

/// 管理 TRON 查询、编辑结果和前台监控；所有发布状态只在主线程修改。
@MainActor
final class StopwatchState: ObservableObject {
    @Published var lapTag: String {
        didSet {
            // 解锁码不能成为持久化查询地址；其他输入原样保留，查询前统一去空白。
            if lapTag.trimmingCharacters(in: .whitespacesAndNewlines) == "5201314" {
                self.defaults.removeObject(forKey: Self.savedAddressKey)
            } else {
                self.defaults.set(lapTag, forKey: Self.savedAddressKey)
            }
            guard oldValue != lapTag else { return }
            resetForTagChange()
        }
    }
    @Published var kind: LapKind {
        didSet {
            self.defaults.set(kind.rawValue, forKey: Self.savedKindKey)
            guard oldValue != kind else { return }
            resetCursor()
            clearQueryOutput()
            message = nil
        }
    }
    /// UI 可直接编辑此属性；自动刷新通过独立基线判断是否仍可替换内容。
    @Published var resultText: String {
        didSet { self.defaults.set(resultText, forKey: Self.savedResultTextKey) }
    }
    @Published private(set) var records: [LapRecord] = []
    @Published private(set) var metrics: StopwatchMetrics?
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    @Published private(set) var monitorMessage: String?
    @Published private(set) var cursor: String?
    @Published var autoLap = false {
        didSet {
            guard oldValue != autoLap else { return }
            updateAutoLap()
        }
    }

    private let engine: StopwatchEngine
    private let defaults: UserDefaults
    private var autoLapTask: Task<Void, Never>?
    private var recordsTask: Task<Void, Never>?
    private var metricsTask: Task<Void, Never>?
    private var recordsGeneration = 0
    private var metricsGeneration = 0
    private var recordsLoading = false
    private var metricsLoading = false
    private var isSceneActive = true
    private var hasLoadedRecords = false
    // nil 表示尚未建立监控基线；空集合表示已确认当前地址暂无交易。
    private var monitorKnownIDs: Set<String>?
    private var generatedResultText: String {
        didSet { self.defaults.set(generatedResultText, forKey: Self.savedGeneratedTextKey) }
    }

    // 沿用已有地址与编辑文本的有效存储键；模式及自动生成基线单独保存。
    private static let savedAddressKey = "stopwatch.lastLapTag"
    private static let savedResultTextKey = "stopwatch.resultText"
    private static let savedGeneratedTextKey = "stopwatch.generatedResultText"
    private static let savedKindKey = "stopwatch.lastQueryKind"

    init(engine: StopwatchEngine = .shared, defaults: UserDefaults = .standard) {
        self.engine = engine
        self.defaults = defaults
        let savedAddress = defaults.string(forKey: Self.savedAddressKey) ?? ""
        let isUnlockCode = savedAddress.trimmingCharacters(in: .whitespacesAndNewlines) == "5201314"
        self.lapTag = isUnlockCode ? "" : savedAddress
        self.kind = LapKind(rawValue: defaults.string(forKey: Self.savedKindKey) ?? "") ?? .lap
        self.resultText = defaults.string(forKey: Self.savedResultTextKey) ?? ""
        self.generatedResultText = defaults.string(forKey: Self.savedGeneratedTextKey) ?? ""
        if isUnlockCode { defaults.removeObject(forKey: Self.savedAddressKey) }
    }

    deinit {
        autoLapTask?.cancel()
        recordsTask?.cancel()
        metricsTask?.cancel()
    }

    /// 切换查询类型并加载第一页；仅实际切换类型时清除上一类型的编辑内容。
    func query(_ requestedKind: LapKind) {
        kind = requestedKind
        start(reset: true)
    }

    /// 用户明确选择恢复时，用当前已加载记录替换编辑内容，并更新自动生成基线。
    func restoreQueryOutput() {
        let generated = makeQueryOutput()
        generatedResultText = generated
        resultText = generated
    }

    /// reset 为 true 时查询第一页，否则按当前游标追加；同地址刷新保留已有内容直到成功。
    func start(reset: Bool = true) {
        let tag = lapTag.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedKind = kind
        let requestedCursor = reset ? nil : cursor
        guard !tag.isEmpty else { message = "请输入 TRON 地址。"; return }
        if !reset && requestedCursor == nil {
            message = "没有更多交易记录。"
            return
        }
        recordsTask?.cancel()
        recordsGeneration &+= 1
        let generation = recordsGeneration
        recordsLoading = true
        message = nil
        if reset {
            cursor = nil
            // 新一轮查询开始前清除旧指标，避免网络失败时继续显示上一轮数据。
            metricsTask?.cancel()
            metricsTask = nil
            metricsGeneration &+= 1
            metricsLoading = false
            metrics = nil
        }
        updateLoading()
        recordsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await engine.records(tag: tag, kind: requestedKind, cursor: requestedCursor)
                guard !Task.isCancelled,
                      self.recordsGeneration == generation,
                      self.kind == requestedKind,
                      self.lapTag.trimmingCharacters(in: .whitespacesAndNewlines) == tag else { return }
                if reset {
                    self.records = page.records
                } else {
                    self.records.append(contentsOf: page.records)
                }
                self.hasLoadedRecords = true
                self.cursor = page.cursor
                self.message = page.records.isEmpty ? "暂无交易记录。" : nil
                self.updateMonitorSnapshot(page.records, isFirstPage: reset)
                // 只有编辑器仍等于上一次自动生成内容时才更新；手动编辑一直保留。
                if self.resultText == self.generatedResultText {
                    self.restoreQueryOutput()
                }
                self.refreshMetrics(for: tag)
            } catch is CancellationError {
                return
            } catch {
                guard self.recordsGeneration == generation else { return }
                let text = self.errorText(error)
                self.message = text
                if self.autoLap && self.isSceneActive {
                    self.monitorMessage = "监控刷新失败：\(text)"
                }
            }
            guard self.recordsGeneration == generation else { return }
            self.recordsLoading = false
            self.recordsTask = nil
            self.updateLoading()
        }
    }

    func refreshMetrics() {
        let tag = lapTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { message = "请输入 TRON 地址。"; return }
        refreshMetrics(for: tag)
    }

    /// UI 应在出现及 scenePhase 变化时传入前台状态；离开管理器时传 false 停止轮询。
    func setSceneActive(_ active: Bool) {
        guard isSceneActive != active else { return }
        isSceneActive = active
        if autoLap { updateAutoLap() }
    }

    private func refreshMetrics(for tag: String) {
        metricsTask?.cancel()
        metricsGeneration &+= 1
        let generation = metricsGeneration
        metricsLoading = true
        updateLoading()
        metricsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await engine.metrics(tag: tag)
                guard !Task.isCancelled,
                      self.metricsGeneration == generation,
                      self.lapTag.trimmingCharacters(in: .whitespacesAndNewlines) == tag else { return }
                self.metrics = value
            } catch is CancellationError {
                return
            } catch {
                guard self.metricsGeneration == generation else { return }
                self.message = self.errorText(error)
            }
            guard self.metricsGeneration == generation,
                  self.lapTag.trimmingCharacters(in: .whitespacesAndNewlines) == tag else { return }
            self.metricsLoading = false
            self.metricsTask = nil
            self.updateLoading()
        }
    }

    func resetCursor() {
        recordsTask?.cancel()
        recordsTask = nil
        recordsGeneration &+= 1
        recordsLoading = false
        cursor = nil
        records = []
        hasLoadedRecords = false
        monitorKnownIDs = nil
        monitorMessage = autoLap ? "监控等待当前地址的首次查询。" : nil
        metricsTask?.cancel()
        metricsTask = nil
        metricsGeneration &+= 1
        metricsLoading = false
        metrics = nil
        updateLoading()
    }

    private func resetForTagChange() {
        resetCursor()
        clearQueryOutput()
        message = nil
    }

    private func clearQueryOutput() {
        generatedResultText = ""
        resultText = ""
    }

    private func updateLoading() {
        isLoading = recordsLoading || metricsLoading
    }

    /// 监控只在前台运行，每十秒加载第一页；请求仍受 generation 和取消检查保护。
    private func updateAutoLap() {
        autoLapTask?.cancel()
        autoLapTask = nil
        guard autoLap else {
            monitorKnownIDs = nil
            monitorMessage = nil
            return
        }
        guard isSceneActive else {
            monitorMessage = "监控已暂停，回到前台后继续。"
            return
        }
        if monitorKnownIDs == nil && hasLoadedRecords {
            monitorKnownIDs = Set(records.map(\.id))
        }
        monitorMessage = "监控已开启，每 10 秒检查新交易。"
        autoLapTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard let self, self.autoLap, self.isSceneActive else { return }
                guard !self.isLoading else { continue }
                self.start(reset: true)
            }
        }
    }

    private func updateMonitorSnapshot(_ page: [LapRecord], isFirstPage: Bool) {
        guard autoLap, isSceneActive else { return }
        let pageIDs = Set(page.map(\.id))
        guard let knownIDs = monitorKnownIDs else {
            monitorKnownIDs = pageIDs
            monitorMessage = "监控中，已建立当前交易基线。"
            return
        }
        // 分页返回的是更早的历史交易，不应作为新交易提醒。
        if isFirstPage {
            let newCount = pageIDs.subtracting(knownIDs).count
            monitorMessage = newCount > 0
                ? "发现 \(newCount) 笔新的 \(kind.rawValue) 交易。"
                : "监控中，本次未发现新交易。"
        }
        monitorKnownIDs = knownIDs.union(pageIDs)
    }

    private func makeQueryOutput() -> String {
        let address = lapTag.trimmingCharacters(in: .whitespacesAndNewlines)
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return records.enumerated().map { index, record in
            // Base58Check 地址区分大小写；不能用忽略大小写的比较判断收支。
            let incoming = record.to == address
            let direction = incoming ? "收入" : "支出"
            let sign = incoming ? "+" : "-"
            let amount = NSDecimalNumber(decimal: record.amount).stringValue
            let date = Date(timeIntervalSince1970: TimeInterval(record.timestamp) / 1_000)
            let time = dateFormatter.string(from: date)
            return [
                "#\(index + 1)",
                "交易ID：\(record.id)",
                "发送方：\(record.from)",
                "接收方：\(record.to)",
                "\(direction)：\(sign)\(amount) \(record.label)",
                "北京时间：\(time)"
            ].joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private func errorText(_ error: Error) -> String {
        TronErrorMessage.describe(error)
    }
}
