import Foundation
import SwiftUI

@MainActor
final class StopwatchState: ObservableObject {
    @Published var lapTag: String {
        didSet { UserDefaults.standard.set(lapTag, forKey: Self.savedLapTagKey) }
    }
    @Published var kind: LapKind = .lap
    @Published private(set) var records: [LapRecord] = []
    @Published private(set) var metrics: StopwatchMetrics?
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    @Published private(set) var cursor: String?
    @Published var autoLap = false { didSet { updateAutoLap() } }

    private let engine: StopwatchEngine
    private var autoLapTask: Task<Void, Never>?
    private static let savedLapTagKey = "stopwatch.lastLapTag"

    init(engine: StopwatchEngine = .shared) {
        self.engine = engine
        self.lapTag = UserDefaults.standard.string(forKey: Self.savedLapTagKey) ?? ""
    }

    deinit { autoLapTask?.cancel() }

    func start(reset: Bool = true) {
        let tag = lapTag.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedKind = kind
        let requestedCursor = reset ? nil : cursor
        guard !tag.isEmpty else { message = "Enter a lap tag first."; return }
        isLoading = true
        message = nil
        Task {
            do {
                let page = try await engine.records(tag: tag, kind: requestedKind, cursor: requestedCursor)
                if reset { records = page.records } else { records.append(contentsOf: page.records) }
                cursor = page.cursor
                message = page.records.isEmpty ? "No laps found." : nil
            } catch { message = error.localizedDescription }
            isLoading = false
        }
    }

    func refreshMetrics() {
        let tag = lapTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        Task {
            do { metrics = try await engine.metrics(tag: tag) }
            catch { message = error.localizedDescription }
        }
    }

    func resetCursor() { cursor = nil; records = [] }

    private func updateAutoLap() {
        autoLapTask?.cancel()
        guard autoLap else { return }
        autoLapTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                self?.start(reset: true)
                self?.refreshMetrics()
            }
        }
    }
}
