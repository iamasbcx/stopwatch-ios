import CryptoKit
import Foundation

enum StopwatchEngineError: LocalizedError {
    case invalidTag
    case invalidInput(String)
    case http(Int)
    case malformedResponse
    case invalidResponse(String)
    case nodeRejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidTag: return "请输入有效的 TRON 地址。"
        case let .invalidInput(message): return message
        case let .http(code): return "TRON 节点返回 HTTP \(code)。"
        case .malformedResponse: return "TRON 节点返回的数据无法解析。"
        case let .invalidResponse(message): return "节点数据异常：\(message)"
        case let .nodeRejected(message): return "节点返回：\(message)"
        }
    }
}

/// 供界面统一显示中文错误；节点返回内容保留原文，私钥不参与错误格式化。
enum TronErrorMessage {
    static func describe(_ error: Error) -> String {
        if let error = error as? StopwatchEngineError { return error.localizedDescription }
        if let error = error as? TronSignerError { return error.localizedDescription }
        if error is CancellationError { return "操作已取消。" }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return "操作已取消。"
            case .timedOut: return "网络请求超时，请稍后重试。"
            case .notConnectedToInternet, .networkConnectionLost: return "网络连接不可用，请检查网络。"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "无法连接 TRON 节点，请稍后重试。"
            default: return "网络请求失败（\(error.errorCode)）：\(error.localizedDescription)"
            }
        }
        return "操作失败：\(error.localizedDescription)"
    }
}

final class StopwatchEngine {
    static let shared = StopwatchEngine()
    private let baseURL = URL(string: "https://api.trongrid.io")!
    private let contractTag = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func records(tag: String, kind: LapKind, cursor: String?) async throws -> LapPage {
        let normalized = try normalizedAddress(tag)
        let path = kind == .lap ? "v1/accounts/\(normalized)/transactions" : "v1/accounts/\(normalized)/transactions/trc20"
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "order_by", value: "block_timestamp,desc"),
            URLQueryItem(name: "only_confirmed", value: "true")
        ]
        if let cursor, !cursor.isEmpty { components.queryItems?.append(URLQueryItem(name: "fingerprint", value: cursor)) }
        let root = try await getJSON(components.url!)
        guard let rows = root["data"] as? [[String: Any]] else { throw StopwatchEngineError.malformedResponse }
        let parsed: [LapRecord]
        if kind == .lap { parsed = parseLap(rows) }
        else { parsed = try parseSplit(rows) }
        let meta = root["meta"] as? [String: Any]
        return LapPage(records: parsed, cursor: meta?["fingerprint"] as? String)
    }

    func metrics(tag: String) async throws -> StopwatchMetrics {
        let normalized = try normalizedAddress(tag)
        let accountRoot = try await getJSON(baseURL.appendingPathComponent("v1/accounts/\(normalized)"))
        guard let accounts = accountRoot["data"] as? [[String: Any]] else {
            throw StopwatchEngineError.malformedResponse
        }
        // 未激活账户返回空数组；已激活账户的零值 protobuf 字段允许省略。
        let account = accounts.first ?? [:]
        let primary = decimal(try nonnegativeInt64(account["balance"])) / Decimal(1_000_000)
        let resource = try await postJSON(path: "wallet/getaccountresource", body: ["address": normalized, "visible": true])
        let focusUsed = try nonnegativeInt64(resource["EnergyUsed"])
        let focusLimit = try nonnegativeInt64(resource["EnergyLimit"])
        let rangeUsed = try resourceTotal(resource["freeNetUsed"], resource["NetUsed"])
        let rangeLimit = try resourceTotal(resource["freeNetLimit"], resource["NetLimit"])
        let secondary = try await fetchContractValue(tag: normalized)
        return StopwatchMetrics(primary: primary, secondary: secondary, focusUsed: focusUsed, focusLimit: focusLimit, rangeUsed: rangeUsed, rangeLimit: rangeLimit)
    }

    func details(tag: String) async throws -> SplitDetails {
        let normalized = try normalizedAddress(tag)
        let root = try await postJSON(path: "wallet/getaccount", body: ["address": normalized, "visible": true])
        return SplitDetails(
            base: normalized,
            code: addressHex(normalized) ?? "",
            owner: parsePermission(root["owner_permission"] as? [String: Any]),
            active: (root["active_permission"] as? [[String: Any]] ?? []).compactMap(parsePermission),
            witness: parsePermission(root["witness_permission"] as? [String: Any])
        )
    }

    func send(kind: LapKind, privateKey: String, to: String, amount: String) async throws -> LapResult {
        guard !privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StopwatchEngineError.invalidInput("请填写私钥、目标地址和金额。")
        }
        let destination = try normalizedAddress(to)
        guard let value = Decimal(string: amount.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else {
            throw StopwatchEngineError.invalidInput("金额必须大于零。")
        }
        let key = privateKey.trimmingCharacters(in: .whitespacesAndNewlines)

        let blockRoot = try await getJSON(baseURL.appendingPathComponent("wallet/getnowblock"))
        guard let blockID = blockRoot["blockID"] as? String, blockID.count == 64,
              let header = blockRoot["block_header"] as? [String: Any],
              let rawData = header["raw_data"] as? [String: Any],
              let timestampValue = rawData["timestamp"] else {
            throw StopwatchEngineError.malformedResponse
        }
        let blockTimestamp = int64(timestampValue)
        let ref = BlockReference(
            blockIDHex: blockID,
            expirationMs: blockTimestamp + 60_000,
            timestampMs: blockTimestamp + 1_000)

        let built: BuiltTransaction
        switch kind {
        case .lap:
            let sun = try TronSigner.sunAmount(value)
            built = try TronSigner.buildTRXTransfer(privateKeyHex: key, toAddress: destination, amountSun: sun, ref: ref)
        case .split:
            let base = try TronSigner.baseUnits(value, decimals: 6)
            built = try TronSigner.buildTRC20Transfer(
                privateKeyHex: key,
                contractAddress: TronSigner.usdtContractAddress,
                toAddress: destination,
                amountBaseUnits: base,
                ref: ref)
        }

        let response = try await postJSON(path: "wallet/broadcasttransaction", body: [
            "txID": built.txid,
            "raw_data_hex": built.rawHex,
            "raw_data": built.rawJSON,
            "signature": [built.signatureHex],
            "visible": false
        ])
        if let result = response["result"] as? Bool, result {
            return LapResult(success: true, reference: (response["txid"] as? String) ?? built.txid, message: "节点已接受广播。")
        }
        let rawMessage = response["message"] as? String ?? ""
        let readable = decodeHexMessage(rawMessage) ?? rawMessage
        let message: String
        if !readable.isEmpty {
            message = "节点返回：\(readable)"
        } else if let code = response["code"] as? String, !code.isEmpty {
            message = "节点返回：\(code)"
        } else {
            message = "节点拒绝广播。"
        }
        return LapResult(success: false, reference: built.txid, message: message)
    }

    func deriveTime(privateKey: String) throws -> String {
        try TronSigner.address(privateKeyHex: privateKey)
    }

    private func decodeHexMessage(_ text: String) -> String? {
        guard text.count % 2 == 0, text.allSatisfy(\.isHexDigit) else { return nil }
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let value = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(value)
            index = next
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private func normalizedAddress(_ tag: String) throws -> String {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count == 34, normalized.first == "T" else {
            throw StopwatchEngineError.invalidTag
        }
        _ = try TronSigner.decodeAddress(normalized)
        return normalized
    }

    private func getJSON(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try check(response)
        return try decodedResponse(data)
    }

    private func postJSON(path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try check(response)
        return try decodedResponse(data)
    }

    /// HTTP 成功不代表节点业务成功；明确报出节点错误，避免余额失败被解释成零。
    private func decodedResponse(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw StopwatchEngineError.malformedResponse
        }
        if let message = (root["Error"] as? String) ?? (root["error"] as? String), !message.isEmpty {
            throw StopwatchEngineError.nodeRejected(message)
        }
        if let success = root["success"] as? Bool, !success {
            throw StopwatchEngineError.nodeRejected((root["message"] as? String) ?? "请求未成功。")
        }
        return root
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw StopwatchEngineError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else { throw StopwatchEngineError.http(http.statusCode) }
    }

    private func parseLap(_ rows: [[String: Any]]) -> [LapRecord] {
        rows.compactMap { row in
            if let results = row["ret"] as? [[String: Any]],
               results.contains(where: { ($0["contractRet"] as? String) != nil && ($0["contractRet"] as? String) != "SUCCESS" }) {
                return nil
            }
            guard let raw = row["raw_data"] as? [String: Any],
                  let contracts = raw["contract"] as? [[String: Any]],
                  let contract = contracts.first(where: { ($0["type"] as? String) == "TransferContract" }),
                  let parameter = contract["parameter"] as? [String: Any],
                  let value = parameter["value"] as? [String: Any],
                  let from = value["owner_address"] as? String,
                  let to = value["to_address"] as? String else { return nil }
            let base = int64(value["amount"])
            let timestamp = int64(raw["timestamp"])
            return LapRecord(id: row["txID"] as? String ?? UUID().uuidString, from: displayAddress(from), to: displayAddress(to), label: "TRX", amount: decimal(base) / Decimal(1_000_000), amountBase: base, timestamp: timestamp, timeText: formatDate(timestamp))
        }
    }

    private func parseSplit(_ rows: [[String: Any]]) throws -> [LapRecord] {
        try rows.map { row in
            guard let from = row["from"] as? String, let to = row["to"] as? String,
                  let info = row["token_info"] as? [String: Any], let precision = info["decimals"] else {
                throw StopwatchEngineError.malformedResponse
            }
            // 全部 TRC20 代币共用查询接口，不能把缺失或异常精度猜测为 USDT 的 6 位。
            let decimalsValue = try nonnegativeInt64(precision)
            guard decimalsValue <= 30 else {
                throw StopwatchEngineError.invalidResponse("TRC20 代币精度必须在 0...30 范围内。")
            }
            let decimals = Int(decimalsValue)
            let rawText: String
            if let value = row["value"] as? String { rawText = value }
            else if let value = row["value"] as? NSNumber { rawText = value.stringValue }
            else { throw StopwatchEngineError.malformedResponse }
            let raw = try exactUnsignedDecimal(rawText, radix: 10, maxLength: 78)
            let divisor = (0..<decimals).reduce(Decimal(1)) { value, _ in value * 10 }
            let timestamp = int64(row["block_timestamp"])
            return LapRecord(id: row["transaction_id"] as? String ?? UUID().uuidString, from: displayAddress(from), to: displayAddress(to), label: info["symbol"] as? String ?? "TRC20", amount: raw / divisor, amountBase: nil, timestamp: timestamp, timeText: formatDate(timestamp))
        }
    }

    private func fetchContractValue(tag: String) async throws -> Decimal {
        guard let owner = addressHex(tag), let contract = addressHex(contractTag) else {
            throw StopwatchEngineError.malformedResponse
        }
        let parameter = String(repeating: "0", count: 24) + String(owner.dropFirst(2))
        let root = try await postJSON(path: "wallet/triggerconstantcontract", body: ["owner_address": owner, "contract_address": contract, "function_selector": "balanceOf(address)", "parameter": parameter, "visible": false])
        if let result = root["result"] as? [String: Any], let success = result["result"] as? Bool, !success {
            let message = (result["message"] as? String) ?? (result["code"] as? String) ?? "USDT 余额查询失败。"
            throw StopwatchEngineError.nodeRejected(decodeHexMessage(message) ?? message)
        }
        guard let value = (root["constant_result"] as? [String])?.first, value.count == 64 else {
            throw StopwatchEngineError.malformedResponse
        }
        let balance = try exactUnsignedDecimal(value, radix: 16, maxLength: 64)
        return balance / Decimal(1_000_000)
    }

    private func parsePermission(_ raw: [String: Any]?) -> SplitPermission? {
        guard let raw else { return nil }
        let keys = (raw["keys"] as? [[String: Any]] ?? []).map {
            SplitKey(address: displayAddress($0["address"] as? String ?? ""), weight: int64($0["weight"]))
        }
        return SplitPermission(name: raw["permission_name"] as? String ?? "权限", threshold: int64(raw["threshold"]), operations: raw["operations"] as? String ?? "", keys: keys)
    }

    private func formatDate(_ milliseconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)) + " 北京时间"
    }

    private func int64(_ value: Any?) -> Int64 {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) ?? 0 }
        return 0
    }

    private func decimal(_ value: Int64) -> Decimal { Decimal(string: String(value)) ?? 0 }

    private func nonnegativeInt64(_ value: Any?) throws -> Int64 {
        guard let value else { return 0 }
        let text: String
        if let value = value as? String { text = value }
        else if let value = value as? NSNumber { text = value.stringValue }
        else { throw StopwatchEngineError.malformedResponse }
        guard let number = Int64(text), number >= 0 else {
            throw StopwatchEngineError.invalidResponse("数值不是有效的非负整数。")
        }
        return number
    }

    private func resourceTotal(_ first: Any?, _ second: Any?) throws -> Int64 {
        let lhs = try nonnegativeInt64(first)
        let rhs = try nonnegativeInt64(second)
        let total = lhs.addingReportingOverflow(rhs)
        guard !total.overflow else { throw StopwatchEngineError.invalidResponse("资源总量超出范围。") }
        return total.partialValue
    }

    /// 对节点返回的整数逐位精确解析；超长或超出 Decimal 精度时拒绝显示错误金额。
    private func exactUnsignedDecimal(_ text: String, radix: Int, maxLength: Int) throws -> Decimal {
        guard !text.isEmpty, text.utf8.count <= maxLength else { throw StopwatchEngineError.malformedResponse }
        var result = Decimal(0)
        var base = Decimal(radix)
        for byte in text.utf8 {
            let value: UInt8
            switch byte {
            case 48...57: value = byte - 48
            case 65...70 where radix == 16: value = byte - 65 + 10
            case 97...102 where radix == 16: value = byte - 97 + 10
            default: throw StopwatchEngineError.malformedResponse
            }
            var digit = Decimal(Int(value))
            var product = Decimal()
            var sum = Decimal()
            guard NSDecimalMultiply(&product, &result, &base, .plain) == .noError,
                  NSDecimalAdd(&sum, &product, &digit, .plain) == .noError else {
                throw StopwatchEngineError.invalidResponse("金额超出可精确显示的范围。")
            }
            result = sum
        }
        return result
    }

    private func addressHex(_ address: String) -> String? {
        guard let payload = try? TronSigner.decodeAddress(address) else { return nil }
        return TronSigner.hex(payload)
    }

    /// 将 TronGrid 返回的 21 字节十六进制地址转换为 Base58Check 地址。
    /// v1 交易接口通常返回 `41...`，界面和用户输入使用 `T...`。
    private func displayAddress(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 42, value.lowercased().hasPrefix("41"), value.allSatisfy({ $0.isHexDigit }) else { return value }
        let payload = TronSigner.unhex(value)
        let first = Data(SHA256.hash(data: Data(payload)))
        let checksum = Data(SHA256.hash(data: first)).prefix(4)
        return TronSigner.base58Encode(payload + Array(checksum))
    }
}

private extension Character {
    var isHexDigit: Bool {
        switch self {
        case "0"..."9", "a"..."f", "A"..."F": return true
        default: return false
        }
    }
}


