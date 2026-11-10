import CryptoKit
import Foundation

enum StopwatchEngineError: LocalizedError {
    case invalidTag
    case invalidInput(String)
    case http(Int)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidTag: return "Enter a valid lap tag."
        case let .invalidInput(message): return message
        case let .http(code): return "The timing service returned HTTP \(code)."
        case .malformedResponse: return "The timing service returned an unreadable response."
        }
    }
}

final class StopwatchEngine {
    static let shared = StopwatchEngine()
    private let baseURL = URL(string: "https://api.trongrid.io")!
    private let contractTag = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func records(tag: String, kind: LapKind, cursor: String?) async throws -> LapPage {
        try validateTag(tag)
        let path = kind == .lap ? "v1/accounts/\(tag)/transactions" : "v1/accounts/\(tag)/transactions/trc20"
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "order_by", value: "block_timestamp,desc"),
            URLQueryItem(name: "only_confirmed", value: "true")
        ]
        if kind == .split { components.queryItems?.append(URLQueryItem(name: "contract_address", value: contractTag)) }
        if let cursor, !cursor.isEmpty { components.queryItems?.append(URLQueryItem(name: "fingerprint", value: cursor)) }
        let root = try await getJSON(components.url!)
        guard let rows = root["data"] as? [[String: Any]] else { throw StopwatchEngineError.malformedResponse }
        let parsed = kind == .lap ? parseLap(rows) : parseSplit(rows)
        let meta = root["meta"] as? [String: Any]
        return LapPage(records: parsed, cursor: meta?["fingerprint"] as? String)
    }

    func metrics(tag: String) async throws -> StopwatchMetrics {
        try validateTag(tag)
        let accountRoot = try await getJSON(baseURL.appendingPathComponent("v1/accounts/\(tag)"))
        let account = (accountRoot["data"] as? [[String: Any]])?.first ?? [:]
        let primary = decimal(int64(account["balance"])) / Decimal(1_000_000)
        let resource = try await postJSON(path: "wallet/getaccountresource", body: ["address": tag, "visible": true])
        let focusUsed = int64(resource["EnergyUsed"])
        let focusLimit = int64(resource["EnergyLimit"])
        let rangeUsed = int64(resource["freeNetUsed"]) + int64(resource["NetUsed"])
        let rangeLimit = int64(resource["freeNetLimit"]) + int64(resource["NetLimit"])
        let secondary = try await fetchContractValue(tag: tag)
        return StopwatchMetrics(primary: primary, secondary: secondary, focusUsed: focusUsed, focusLimit: focusLimit, rangeUsed: rangeUsed, rangeLimit: rangeLimit)
    }

    func details(tag: String) async throws -> SplitDetails {
        try validateTag(tag)
        let root = try await postJSON(path: "wallet/getaccount", body: ["address": tag, "visible": true])
        return SplitDetails(
            base: tag,
            code: addressHex(tag) ?? "",
            owner: parsePermission(root["owner_permission"] as? [String: Any]),
            active: (root["active_permission"] as? [[String: Any]] ?? []).compactMap(parsePermission),
            witness: parsePermission(root["witness_permission"] as? [String: Any])
        )
    }

    func send(kind: LapKind, privateKey: String, to: String, amount: String) async throws -> LapResult {
        guard !privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StopwatchEngineError.invalidInput("Complete the key, destination, and amount fields.")
        }
        try validateTag(to)
        guard let value = Decimal(string: amount.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else {
            throw StopwatchEngineError.invalidInput("Amount must be greater than zero.")
        }
        let key = privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = to.trimmingCharacters(in: .whitespacesAndNewlines)

        let blockRoot = try await getJSON(baseURL.appendingPathComponent("wallet/getnowblock"))
        guard let blockID = blockRoot["blockID"] as? String, blockID.count == 64,
              let header = blockRoot["block_header"] as? [String: Any],
              let rawData = header["raw_data"] as? [String: Any],
              let blockTimestamp = int64(rawData["timestamp"]) else {
            throw StopwatchEngineError.malformedResponse
        }
        let ref = TronSigner.BlockReference(
            blockIDHex: blockID,
            expirationMs: blockTimestamp + 60_000,
            timestampMs: blockTimestamp + 1_000)

        let built: TronSigner.BuiltTransaction
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
            "raw_data": built.rawJSON,
            "signature": [built.signatureHex],
            "visible": false
        ])
        if let result = response["result"] as? Bool, result {
            return LapResult(success: true, reference: (response["txid"] as? String) ?? built.txid, message: "Broadcast accepted.")
        }
        let rawMessage = response["message"] as? String ?? ""
        let readable = decodeHexMessage(rawMessage) ?? rawMessage
        let message = readable.isEmpty ? ((response["code"] as? String) ?? "The node rejected the broadcast.") : readable
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

    private func validateTag(_ tag: String) throws {
        guard tag.count == 34, tag.first == "T", addressHex(tag) != nil else { throw StopwatchEngineError.invalidTag }
    }

    private func getJSON(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try check(response)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw StopwatchEngineError.malformedResponse }
        return object
    }

    private func postJSON(path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try check(response)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw StopwatchEngineError.malformedResponse }
        return object
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw StopwatchEngineError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else { throw StopwatchEngineError.http(http.statusCode) }
    }

    private func parseLap(_ rows: [[String: Any]]) -> [LapRecord] {
        rows.compactMap { row in
            guard let raw = row["raw_data"] as? [String: Any],
                  let contracts = raw["contract"] as? [[String: Any]],
                  let contract = contracts.first(where: { ($0["type"] as? String) == "TransferContract" }),
                  let parameter = contract["parameter"] as? [String: Any],
                  let value = parameter["value"] as? [String: Any],
                  let from = value["owner_address"] as? String,
                  let to = value["to_address"] as? String else { return nil }
            let base = int64(value["amount"])
            let timestamp = int64(raw["timestamp"])
            return LapRecord(id: row["txID"] as? String ?? UUID().uuidString, from: from, to: to, label: "TRX", amount: decimal(base) / Decimal(1_000_000), amountBase: base, timestamp: timestamp, timeText: formatDate(timestamp))
        }
    }

    private func parseSplit(_ rows: [[String: Any]]) -> [LapRecord] {
        rows.compactMap { row in
            guard let from = row["from"] as? String, let to = row["to"] as? String else { return nil }
            let info = row["token_info"] as? [String: Any] ?? [:]
            let decimals = info["decimals"] == nil ? 6 : Int(int64(info["decimals"]))
            let raw = Decimal(string: row["value"] as? String ?? "0") ?? 0
            let divisor = (0..<max(0, decimals)).reduce(Decimal(1)) { value, _ in value * 10 }
            let timestamp = int64(row["block_timestamp"])
            return LapRecord(id: row["transaction_id"] as? String ?? UUID().uuidString, from: from, to: to, label: info["symbol"] as? String ?? "TRC20", amount: raw / divisor, amountBase: nil, timestamp: timestamp, timeText: formatDate(timestamp))
        }
    }

    private func fetchContractValue(tag: String) async throws -> Decimal {
        guard let owner = addressHex(tag), let contract = addressHex(contractTag) else { return 0 }
        let parameter = String(repeating: "0", count: 24) + String(owner.dropFirst(2))
        let root = try await postJSON(path: "wallet/triggerconstantcontract", body: ["owner_address": owner, "contract_address": contract, "function_selector": "balanceOf(address)", "parameter": parameter, "visible": false])
        guard let value = (root["constant_result"] as? [String])?.first else { return 0 }
        return decimalFromHex(value) / Decimal(1_000_000)
    }

    private func parsePermission(_ raw: [String: Any]?) -> SplitPermission? {
        guard let raw else { return nil }
        let keys = (raw["keys"] as? [[String: Any]] ?? []).map { SplitKey(address: $0["address"] as? String ?? "", weight: int64($0["weight"])) }
        return SplitPermission(name: raw["permission_name"] as? String ?? "Permission", threshold: int64(raw["threshold"]), operations: raw["operations"] as? String ?? "", keys: keys)
    }

    private func formatDate(_ milliseconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000))
    }

    private func int64(_ value: Any?) -> Int64 {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) ?? 0 }
        return 0
    }

    private func decimal(_ value: Int64) -> Decimal { Decimal(string: String(value)) ?? 0 }

    private func decimalFromHex(_ value: String) -> Decimal {
        value.reduce(Decimal(0)) { partial, character in
            let digit: Decimal
            switch character.lowercased() {
            case "0"..."9": digit = Decimal(character.wholeNumberValue ?? 0)
            case "a": digit = 10
            case "b": digit = 11
            case "c": digit = 12
            case "d": digit = 13
            case "e": digit = 14
            case "f": digit = 15
            default: digit = 0
            }
            return partial * 16 + digit
        }
    }

    private func addressHex(_ address: String) -> String? {
        guard let decoded = base58Decode(address), decoded.count == 25 else { return nil }
        let payload = decoded.prefix(21)
        let checksum = decoded.suffix(4)
        let first = Data(SHA256.hash(data: Data(payload)))
        let expected = Data(SHA256.hash(data: first))
        guard Data(expected.prefix(4)) == Data(checksum), payload.first == 0x41 else { return nil }
        return payload.map { String(format: "%02x", $0) }.joined()
    }

    private func base58Decode(_ value: String) -> [UInt8]? {
        let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        var bytes: [UInt8] = []
        for character in value {
            guard let digit = alphabet.firstIndex(of: character) else { return nil }
            var carry = digit
            for index in bytes.indices.reversed() {
                let number = Int(bytes[index]) * 58 + carry
                bytes[index] = UInt8(number & 0xff)
                carry = number >> 8
            }
            while carry > 0 {
                bytes.insert(UInt8(carry & 0xff), at: 0)
                carry >>= 8
            }
        }
        for character in value where character == "1" { bytes.insert(0, at: 0) }
        return bytes
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


