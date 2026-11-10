import CryptoKit
import Foundation

/// 直接运行正式 Swift 实现的离线回归；所有断言在 -Onone 与 -O 下均生效。
/// 仅使用公开测试私钥，不读取应用数据、不访问网络，也不构造或广播交易。
@main
struct TronSignerRuntimeTests {
    static func main() throws {
        try testUInt64Normalization()
        try testBase58Division()
        try testBase58Encoding()
        try testAddressRoundTrips()
        try testPrivateKeyVectors()
        try testSignatureVector()
        try testInvalidInputs()
        print("TronSignerRuntimeTests: ALL CHECKS PASSED")
    }

    private static func testUInt64Normalization() throws {
        let cases: [(value: UInt64, limbs: [UInt32], bits: Int)] = [
            (0, [], 0),
            (1, [1], 1),
            (57, [57], 6),
            (58, [58], 6),
            (UInt64(UInt32.max), [UInt32.max], 32),
            (UInt64(UInt32.max) + 1, [0, 1], 33),
            (UInt64.max, [UInt32.max, UInt32.max], 64)
        ]
        for item in cases {
            let value = TronBigInt(u64: item.value)
            try expect(value.limbs == item.limbs, "u64 构造未归一化：\(item.value)")
            try expect(value.bitCount == item.bits, "u64 位数错误：\(item.value)")
            try expect(value.isZero == (item.value == 0), "u64 零值判断错误：\(item.value)")
            let fromBytes = TronBigInt(bytesBE: bytesBE(item.value))
            try expect(TronBigInt.compare(value, fromBytes) == 0, "两种构造入口不一致：\(item.value)")
        }
        for index in 1..<cases.count {
            let lower = TronBigInt(u64: cases[index - 1].value)
            let upper = TronBigInt(u64: cases[index].value)
            try expect(TronBigInt.compare(lower, upper) == -1, "u64 升序比较错误：\(index)")
            try expect(TronBigInt.compare(upper, lower) == 1, "u64 降序比较错误：\(index)")
        }
    }

    private static func testBase58Division() throws {
        let divisor = TronBigInt(u64: 58)
        let values: [UInt64] = [0, 1, 57, 58, 59, 255, UInt64(UInt32.max), UInt64(UInt32.max) + 1, UInt64.max]
        for value in values {
            // 被除数从字节入口构造，模拟 Base58 编码，避免相同构造缺陷互相抵消。
            let dividend = TronBigInt(bytesBE: bytesBE(value))
            let result = TronBigInt.divmod(dividend, divisor)
            let expectedQuotient = TronBigInt(bytesBE: bytesBE(value / 58))
            let expectedRemainder = TronBigInt(bytesBE: bytesBE(value % 58))
            try expect(result.quotient == expectedQuotient, "Base58 除法商错误：\(value)")
            try expect(result.remainder == expectedRemainder, "Base58 除法余数错误：\(value)")
            try expect(TronBigInt.compare(result.remainder, divisor) < 0, "Base58 余数越界：\(value)")
            let rebuilt = TronBigInt.add(TronBigInt.multiply(result.quotient, divisor), result.remainder)
            try expect(rebuilt == dividend, "Base58 除法无法还原被除数：\(value)")
        }
    }

    private static func testBase58Encoding() throws {
        let vectors: [(bytes: [UInt8], text: String)] = [
            ([], ""), ([0], "1"), ([0, 0], "11"), ([1], "2"),
            ([57], "z"), ([58], "21"), ([59], "22"), ([255], "5Q"),
            ([0, 58], "121"), ([0, 0, 255], "115Q")
        ]
        for vector in vectors {
            let encoded = TronSigner.base58Encode(vector.bytes)
            try expect(encoded == vector.text, "Base58 已知向量不匹配：\(vector.text)")
            try expect(TronSigner.base58Decode(vector.text) == vector.bytes, "Base58 解码向量不匹配：\(vector.text)")
        }
        let payloads: [[UInt8]] = [
            [0, 0, 0, 1, 0, 255],
            Array(repeating: 0, count: 32),
            Array(repeating: 255, count: 32),
            [0, 0] + Array(UInt8(0)...UInt8(64))
        ]
        for (index, bytes) in payloads.enumerated() {
            let encoded = TronSigner.base58Encode(bytes)
            try expect(TronSigner.base58Decode(encoded) == bytes, "Base58 往返或前导零丢失：\(index)")
        }
        for text in ["0", "O", "I", "l", "中文", "1 2"] {
            try expect(TronSigner.base58Decode(text) == nil, "Base58 接受非法字符：\(text)")
        }
    }

    private static func testAddressRoundTrips() throws {
        let addresses = [
            "TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC",
            "TALxLgri9eHHDyYicNkWreWt9REKQ5eV4a",
            "TMRyaDePk63uo2MGLJAj3Ki71AfA7CLT4w",
            "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
        ]
        for address in addresses {
            let payload = try TronSigner.decodeAddress(address)
            try expect(payload.count == 21 && payload.first == 0x41, "TRON 地址载荷格式错误")
            let encoded = TronSigner.base58Encode(payload + checksum(payload))
            try expect(encoded == address, "TRON 地址与校验和往返不匹配：\(address)")
        }
    }

    private static func testPrivateKeyVectors() throws {
        // 这些是公开的固定测试向量，禁止将它们用作实际资产账户。
        let vectors = [
            (String(repeating: "0", count: 63) + "1", "TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC"),
            (String(format: "%064llx", UInt64(123456789)), "TMRyaDePk63uo2MGLJAj3Ki71AfA7CLT4w"),
            ("9c8b1f6d3e7a2b5c4d8e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e", "TALxLgri9eHHDyYicNkWreWt9REKQ5eV4a")
        ]
        for (index, vector) in vectors.enumerated() {
            let address = try TronSigner.address(privateKeyHex: vector.0)
            try expect(address == vector.1, "私钥转换地址向量错误：\(index)")
        }
    }

    private static func testSignatureVector() throws {
        let key = try TronSigner.parseKey(String(repeating: "0", count: 63) + "1")
        let digest = Array(SHA256.hash(data: Data("LapTimer-TRON-self-test".utf8)))
        let signature = try TronSigner.sign(key: key, digest: TronBigInt(bytesBE: digest))
        try expect(TronSigner.hex(signature.r) == "e61be4ff45f2585172b6dc96c7b0de19af81c8c05409fff750daa8ea174edee9", "RFC 6979 签名 r 不匹配")
        try expect(TronSigner.hex(signature.s) == "0ddbde08df77866cc0bc7a67882d5118a709b315a2c7100a1c6b7f344db28b25", "RFC 6979 签名 s 不匹配")
        try expect(signature.recid == 1, "RFC 6979 恢复标记不匹配")
    }

    private static func testInvalidInputs() throws {
        let invalidKeys = [
            "", "1", String(repeating: "z", count: 64), String(repeating: "0", count: 64),
            "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141",
            String(repeating: "f", count: 64)
        ]
        for (index, key) in invalidKeys.enumerated() {
            do {
                _ = try TronSigner.address(privateKeyHex: key)
                throw RuntimeTestFailure("私钥转换接受非法私钥：\(index)")
            } catch TronSignerError.invalidKey {
                // 仅接受明确的输入错误；其他异常和测试失败继续向上传递。
            }
        }

        // 此处包含校验和错误的地址，不能把历史截图中抄录的字符串当作有效向量。
        var invalidAddresses = ["", "5201314", "not-an-address", "TLHuPCitAKetRjgvkc3YX61nraU3qyifQn", "TLHuPCitAKetRjgvkc3YX61nraU3qyifQ1"]
        for payload in [[UInt8](repeating: 0, count: 21), [0x41] + [UInt8](repeating: 0, count: 19), [0x41] + [UInt8](repeating: 0, count: 21)] {
            invalidAddresses.append(TronSigner.base58Encode(payload + checksum(payload)))
        }
        for (index, address) in invalidAddresses.enumerated() {
            do {
                _ = try TronSigner.decodeAddress(address)
                throw RuntimeTestFailure("地址解码接受非法输入：\(index)")
            } catch TronSignerError.invalidAddress(_) {
                // 校验错误必须以可处理的错误返回，不能触发数组越界。
            }
        }
    }

    /// 使用标准整数生成独立输入，避免通过待测大整数构造期望值。
    private static func bytesBE(_ value: UInt64) -> [UInt8] {
        stride(from: 56, through: 0, by: -8).map { UInt8(truncatingIfNeeded: value >> $0) }
    }

    private static func checksum(_ payload: [UInt8]) -> [UInt8] {
        let first = SHA256.hash(data: Data(payload))
        return Array(SHA256.hash(data: Data(first)).prefix(4))
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw RuntimeTestFailure(message) }
    }
}

private struct RuntimeTestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ message: String) { description = "测试失败：\(message)" }
}
