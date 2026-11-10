import Foundation

/// 通过真实查询入口验证响应解析；专用 URLProtocol 拦截全部请求，禁止访问真实节点。
@main
struct TronQueryRuntimeTests {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TronQueryFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let engine = StopwatchEngine(session: session)
        let address = "TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC"
        let destination = "TMRyaDePk63uo2MGLJAj3Ki71AfA7CLT4w"

        // TRX 接口返回十六进制地址，必须经过曾触发数组越界的 Base58 编码路径。
        let trx = try await engine.records(tag: address, kind: .lap, cursor: nil)
        try expect(trx.records.count == 1, "TRX 交易数量错误")
        guard let record = trx.records.first else { throw QueryTestFailure("缺少 TRX 交易") }
        try expect(record.id == "fixture-trx", "TRX 交易 ID 错误")
        try expect(record.from == address, "TRX 发送地址转换错误")
        try expect(record.to == destination, "TRX 接收地址转换错误")
        try expect(record.label == "TRX", "TRX 币种错误")
        try expect(record.amount == Decimal(15) / 10, "TRX 金额错误")
        try expect(record.amountBase == 1_500_000, "TRX 原始金额错误")
        try expect(record.timestamp == 1_700_000_000_000, "TRX 时间戳错误")
        try expect(record.timeText == "2023-11-15 06:13:20 北京时间", "TRX 时间显示错误")
        try expect(trx.cursor == "next-page", "TRX 分页游标错误")

        // TRC20 接口通常直接返回 Base58 地址；查询修复不能改变该路径。
        let trc20 = try await engine.records(tag: address, kind: .split, cursor: nil)
        try expect(trc20.records.count == 1, "TRC20 交易数量错误")
        guard let token = trc20.records.first else { throw QueryTestFailure("缺少 TRC20 交易") }
        try expect(token.from == address && token.to == destination, "TRC20 地址被错误修改")
        try expect(token.label == "USDT", "TRC20 币种错误")
        try expect(token.amount == Decimal(1234) / 100, "TRC20 金额错误")
        try expect(token.timestamp == 1_700_000_000_000, "TRC20 时间戳错误")
        try expect(token.timeText == "2023-11-15 06:13:20 北京时间", "TRC20 时间显示错误")

        do {
            _ = try await engine.records(tag: address, kind: .lap, cursor: "http-error")
            throw QueryTestFailure("HTTP 503 应返回错误")
        } catch StopwatchEngineError.http(let status) {
            try expect(status == 503, "HTTP 错误状态被修改")
        }
        print("TronQueryRuntimeTests: ALL CHECKS PASSED")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw QueryTestFailure(message) }
    }
}

/// 不保存可变共享状态；URLSession 的每次请求都由本类同步完成或明确报错。
private final class TronQueryFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let url = request.url,
                  url.host == "api.trongrid.io", request.httpMethod == "GET",
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw QueryTestFailure("查询请求格式错误")
            }
            let fingerprint = components.queryItems?.first { $0.name == "fingerprint" }?.value
            let status = fingerprint == "http-error" ? 503 : 200
            guard let response = HTTPURLResponse(url: url, statusCode: status,
                                                httpVersion: "HTTP/1.1",
                                                headerFields: ["Content-Type": "application/json"]) else {
                throw QueryTestFailure("无法创建模拟 HTTP 响应")
            }
            let data = try responseData(path: url.path)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    // 响应同步交付，不启动网络、后台任务或需要取消的资源。
    override func stopLoading() {}

    private func responseData(path: String) throws -> Data {
        let prefix = "/v1/accounts/TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC/transactions"
        let root: [String: Any]
        switch path {
        case prefix:
            root = [
                "data": [[
                    "txID": "fixture-trx",
                    "ret": [["contractRet": "SUCCESS"]],
                    "raw_data": [
                        "timestamp": Int64(1_700_000_000_000),
                        "contract": [[
                            "type": "TransferContract",
                            "parameter": ["value": [
                                "owner_address": "417e5f4552091a69125d5dfcb7b8c2659029395bdf",
                                "to_address": "417db967bcf885c8ae4bbfdb5ffff5d9ebf96aa0ed",
                                "amount": 1_500_000
                            ]]
                        ]]
                    ]
                ]],
                "meta": ["fingerprint": "next-page"]
            ]
        case prefix + "/trc20":
            root = ["data": [[
                "transaction_id": "fixture-trc20",
                "from": "TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC",
                "to": "TMRyaDePk63uo2MGLJAj3Ki71AfA7CLT4w",
                "token_info": ["symbol": "USDT", "decimals": 6],
                "value": "12340000",
                "block_timestamp": Int64(1_700_000_000_000)
            ]]]
        default:
            throw QueryTestFailure("出现未定义的查询路径：\(path)")
        }
        return try JSONSerialization.data(withJSONObject: root)
    }
}

private struct QueryTestFailure: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { "测试失败：\(message)" }
}
