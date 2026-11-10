import Foundation
import SwiftUI

@MainActor
final class StopwatchState: ObservableObject {
    @Published var lapTag: String {
        didSet {
            UserDefaults.standard.set(lapTag, forKey: Self.savedLapTagKey)
            guard oldValue != lapTag else { return }
            resetForTagChange()
        }
    }
    @Published var kind: LapKind = .lap {
        didSet {
            guard oldValue != kind else { return }
            resetCursor()
        }
    }
    @Published private(set) var records: [LapRecord] = []
    @Published private(set) var metrics: StopwatchMetrics?
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    @Published private(set) var cursor: String?
    @Published var autoLap = false { didSet { updateAutoLap() } }

    private let engine: StopwatchEngine
    private var autoLapTask: Task<Void, Never>?
    private var recordsTask: Task<Void, Never>?
    private var metricsTask: Task<Void, Never>?
    private var recordsGeneration = 0
    private var metricsGeneration = 0
    private var recordsLoading = false
    private var metricsLoading = false
    private var isSceneActive = true
    private static let savedLapTagKey = "stopwatch.lastLapTag"

    init(engine: StopwatchEngine = .shared) {
        self.engine = engine
        self.lapTag = UserDefaults.standard.string(forKey: Self.savedLapTagKey) ?? ""
    }

    deinit {
        autoLapTask?.cancel()
        recordsTask?.cancel()
        metricsTask?.cancel()
    }

    func start(reset: Bool = true) {
        let tag = lapTag.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedKind = kind
        let requestedCursor = reset ? nil : cursor
        guard !tag.isEmpty else { message = "Enter a lap tag first."; return }
        recordsTask?.cancel()
        recordsGeneration &+= 1
        let generation = recordsGeneration
        recordsLoading = true
        updateLoading()
        message = nil
        if reset {
            records = []
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
                guard !Task.isCancelled, self.recordsGeneration == generation else { return }
                if reset { self.records = page.records } else { self.records.append(contentsOf: page.records) }
                self.cursor = page.cursor
                self.message = page.records.isEmpty ? "No laps found." : nil
                // 首次加载记录后同步指标，避免页面仍显示上一账户或空指标。
                self.refreshMetrics(for: tag)
            } catch is CancellationError {
                return
            } catch {
                guard self.recordsGeneration == generation else { return }
                self.message = error.localizedDescription
            }
            guard self.recordsGeneration == generation else { return }
            self.recordsLoading = false
            self.recordsTask = nil
            self.updateLoading()
        }
    }

    func refreshMetrics() {
        let tag = lapTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        refreshMetrics(for: tag)
    }

    /// 根据 App 生命周期暂停后台轮询，回到前台后重新开始下一轮轮询。
    func setSceneActive(_ active: Bool) {
        isSceneActive = active
        if active {
            if autoLap { updateAutoLap() }
        } else {
            autoLapTask?.cancel()
            autoLapTask = nil
        }
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
            }
            catch is CancellationError { return }
            catch {
                guard self.metricsGeneration == generation else { return }
                self.message = error.localizedDescription
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
        metricsTask?.cancel()
        metricsTask = nil
        metricsGeneration &+= 1
        metricsLoading = false
        metrics = nil
        updateLoading()
    }

    private func resetForTagChange() {
        resetCursor()
        message = nil
    }

    private func updateLoading() {
        isLoading = recordsLoading || metricsLoading
    }

    private func updateAutoLap() {
        autoLapTask?.cancel()
        guard autoLap, isSceneActive else { return }
        autoLapTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                guard let self, self.isSceneActive, !self.isLoading else { continue }
                self.start(reset: true)
            }
        }
    }
}
