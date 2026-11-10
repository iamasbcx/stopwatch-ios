import Foundation

enum LapKind: String, CaseIterable, Identifiable {
    case lap = "TRX"
    case split = "TRC20"
    var id: String { rawValue }

    /// 当前仅支持 TRX 与 USDT 转账，查询类型与转账资产名称分别展示。
    var transferTitle: String { self == .lap ? "TRX" : "USDT" }
}

struct LapRecord: Identifiable, Hashable {
    let id: String
    let from: String
    let to: String
    let label: String
    let amount: Decimal
    let amountBase: Int64?
    let timestamp: Int64
    let timeText: String
}

struct LapPage {
    let records: [LapRecord]
    let cursor: String?
}

struct StopwatchMetrics {
    let primary: Decimal
    let secondary: Decimal
    let focusUsed: Int64
    let focusLimit: Int64
    let rangeUsed: Int64
    let rangeLimit: Int64
}

struct SplitKey: Identifiable {
    let id = UUID()
    let address: String
    let weight: Int64
}

struct SplitPermission: Identifiable {
    let id = UUID()
    let name: String
    let threshold: Int64
    let operations: String
    let keys: [SplitKey]
}

struct SplitDetails {
    let base: String
    let code: String
    let owner: SplitPermission?
    let active: [SplitPermission]
    let witness: SplitPermission?
}

struct LapResult {
    let success: Bool
    let reference: String?
    let message: String
}
