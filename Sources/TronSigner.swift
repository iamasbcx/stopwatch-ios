import CryptoKit
import Foundation

// MARK: - Errors

enum TronSignerError: LocalizedError {
    case invalidKey
    case invalidAddress(String)
    case invalidAmount(String)
    case signatureFailure

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "The key must contain 64 hexadecimal characters and stay inside the secp256k1 range."
        case let .invalidAddress(address):
            return "Invalid TRON address: \(address)."
        case let .invalidAmount(message):
            return message
        case .signatureFailure:
            return "The signer produced an unusable signature; try again."
        }
    }
}

// MARK: - Big integer (little-endian UInt32 limbs)

struct TronBigInt: Equatable {
    var limbs: [UInt32] // little-endian, no trailing zeros

    init(_ limbs: [UInt32] = []) {
        var value = limbs
        while value.last == 0 { value.removeLast() }
        self.limbs = value
    }

    init(u64: UInt64) {
        if u64 == 0 {
            self.limbs = []
        } else {
            self.limbs = [UInt32(truncatingIfNeeded: u64), UInt32(truncatingIfNeeded: u64 >> 32)]
        }
    }

    init(hex: String) {
        self.init(bytesBE: TronSigner.unhex(hex))
    }

    init(bytesBE bytes: [UInt8]) {
        var result: [UInt32] = []
        var index = bytes.count
        while index > 0 {
            var limb: UInt32 = 0
            let start = max(0, index - 4)
            for position in start..<index {
                limb = (limb << 8) | UInt32(bytes[position])
            }
            result.append(limb)
            index = start
        }
        self.init(result)
    }

    init?(decimalString: String) {
        var result = TronBigInt()
        let ten = TronBigInt(u64: 10)
        for character in decimalString {
            guard let digit = character.wholeNumberValue else { return nil }
            result = TronBigInt.add(TronBigInt.multiply(result, ten), TronBigInt(u64: UInt64(digit)))
        }
        self = result
    }

    var isZero: Bool { limbs.isEmpty }

    var bitCount: Int {
        guard let top = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - Int(top.leadingZeroBitCount))
    }

    func bit(_ index: Int) -> Bool {
        let limb = index / 32
        guard limb < limbs.count else { return false }
        return (limbs[limb] >> UInt32(index % 32)) & 1 == 1
    }

    /// Minimal big-endian bytes (empty for zero).
    var bytesBE: [UInt8] {
        var output: [UInt8] = []
        for limb in limbs.reversed() {
            var value = limb
            for _ in 0..<4 {
                output.append(UInt8(truncatingIfNeeded: value >> 24))
                value <<= 8
            }
        }
        return output
    }

    /// Exactly 32 big-endian bytes.
    func bytes32BE() -> [UInt8] {
        let raw = bytesBE
        guard raw.count <= 32 else { return Array(raw.suffix(32)) }
        return [UInt8](repeating: 0, count: 32 - raw.count) + raw
    }

    static func == (lhs: TronBigInt, rhs: TronBigInt) -> Bool { compare(lhs, rhs) == 0 }

    static func compare(_ a: TronBigInt, _ b: TronBigInt) -> Int {
        if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count ? -1 : 1 }
        var index = a.limbs.count - 1
        while index >= 0 {
            if a.limbs[index] != b.limbs[index] { return a.limbs[index] < b.limbs[index] ? -1 : 1 }
            index -= 1
        }
        return 0
    }

    static func add(_ a: TronBigInt, _ b: TronBigInt) -> TronBigInt {
        TronBigInt(addLimbs(a.limbs, b.limbs))
    }

    /// Requires `a >= b`.
    static func subtract(_ a: TronBigInt, _ b: TronBigInt) -> TronBigInt {
        var output: [UInt32] = []
        var borrow: UInt64 = 0
        for index in 0..<a.limbs.count {
            let upper = UInt64(a.limbs[index])
            let lower = (index < b.limbs.count ? UInt64(b.limbs[index]) : 0) + borrow
            if upper >= lower {
                output.append(UInt32(upper - lower))
                borrow = 0
            } else {
                output.append(UInt32(upper &+ (1 << 32) &- lower))
                borrow = 1
            }
        }
        return TronBigInt(output)
    }

    static func multiply(_ a: TronBigInt, _ b: TronBigInt) -> TronBigInt {
        var output = [UInt32](repeating: 0, count: a.limbs.count + b.limbs.count)
        for i in 0..<a.limbs.count {
            var carry: UInt64 = 0
            let ai = UInt64(a.limbs[i])
            for j in 0..<b.limbs.count {
                let current = UInt64(output[i + j]) &+ ai &* UInt64(b.limbs[j]) &+ carry
                output[i + j] = UInt32(truncatingIfNeeded: current)
                carry = current >> 32
            }
            var k = i + b.limbs.count
            while carry != 0 {
                let current = UInt64(output[k]) &+ carry
                output[k] = UInt32(truncatingIfNeeded: current)
                carry = current >> 32
                k += 1
            }
        }
        return TronBigInt(output)
    }

    static func shiftLeftOne(_ a: TronBigInt) -> TronBigInt {
        var output = [UInt32](repeating: 0, count: a.limbs.count + 1)
        for index in 0..<a.limbs.count {
            output[index] = (a.limbs[index] << 1) | (index > 0 ? a.limbs[index - 1] >> 31 : 0)
        }
        if let top = a.limbs.last { output[a.limbs.count] = top >> 31 }
        return TronBigInt(output)
    }

    static func shiftRightOne(_ a: TronBigInt) -> TronBigInt {
        var output = [UInt32](repeating: 0, count: a.limbs.count)
        var index = a.limbs.count - 1
        while index >= 0 {
            output[index] = a.limbs[index] >> 1
            if index + 1 < a.limbs.count { output[index] |= (a.limbs[index + 1] & 1) << 31 }
            index -= 1
        }
        return TronBigInt(output)
    }

    /// Binary long division (shift-subtract).
    static func divmod(_ a: TronBigInt, _ b: TronBigInt) -> (quotient: TronBigInt, remainder: TronBigInt) {
        precondition(!b.isZero, "division by zero")
        if compare(a, b) < 0 { return (TronBigInt(), a) }
        var remainder = TronBigInt()
        var quotient = [UInt32](repeating: 0, count: (a.bitCount + 31) / 32)
        var index = a.bitCount - 1
        while index >= 0 {
            remainder = shiftLeftOne(remainder)
            if a.bit(index) {
                if remainder.limbs.isEmpty { remainder.limbs = [1] } else { remainder.limbs[0] |= 1 }
            }
            if compare(remainder, b) >= 0 {
                remainder = subtract(remainder, b)
                quotient[index / 32] |= 1 << UInt32(index % 32)
            }
            index -= 1
        }
        return (TronBigInt(quotient), remainder)
    }

    static func addMod(_ a: TronBigInt, _ b: TronBigInt, _ modulus: TronBigInt) -> TronBigInt {
        let sum = add(a, b)
        return compare(sum, modulus) >= 0 ? subtract(sum, modulus) : sum
    }

    static func subMod(_ a: TronBigInt, _ b: TronBigInt, _ modulus: TronBigInt) -> TronBigInt {
        compare(a, b) >= 0 ? subtract(a, b) : add(subtract(modulus, b), a)
    }

    static func mulMod(_ a: TronBigInt, _ b: TronBigInt, _ modulus: TronBigInt) -> TronBigInt {
        divmod(multiply(a, b), modulus).remainder
    }

    static func powMod(_ base: TronBigInt, _ exponent: TronBigInt, _ modulus: TronBigInt) -> TronBigInt {
        var result = TronBigInt(u64: 1)
        var factor = base
        for index in 0..<exponent.bitCount {
            if exponent.bit(index) { result = mulMod(result, factor, modulus) }
            factor = mulMod(factor, factor, modulus)
        }
        return result
    }

    /// Fermat inverse: a^(m-2) mod m.
    static func invMod(_ a: TronBigInt, _ modulus: TronBigInt) -> TronBigInt {
        powMod(a, subtract(modulus, TronBigInt(u64: 2)), modulus)
    }

    static func addLimbs(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var output: [UInt32] = []
        var carry: UInt64 = 0
        let count = max(a.count, b.count)
        for index in 0..<count {
            let sum = UInt64(index < a.count ? a[index] : 0) + UInt64(index < b.count ? b[index] : 0) + carry
            output.append(UInt32(truncatingIfNeeded: sum))
            carry = sum >> 32
        }
        if carry != 0 { output.append(UInt32(truncatingIfNeeded: carry)) }
        return output
    }
}

// MARK: - Keccak-256 (little-endian lane convention, XKCP reference)

enum Keccak256 {
    private static let roundConstants: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
        0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
        0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    ]

    private static let rotationOffsets: [[Int]] = [
        [0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61],
        [28, 55, 25, 21, 56], [27, 20, 39, 8, 14],
    ]

    static func hash(_ data: [UInt8]) -> [UInt8] {
        let rate = 136
        var padded = data
        padded.append(0x01)
        while padded.count % rate != rate - 1 { padded.append(0x00) }
        padded.append(0x80)

        var state = [UInt64](repeating: 0, count: 25)
        var blockStart = 0
        while blockStart < padded.count {
            for lane in 0..<(rate / 8) {
                var value: UInt64 = 0
                for byte in 0..<8 {
                    value |= UInt64(padded[blockStart + lane * 8 + byte]) << UInt64(byte * 8)
                }
                state[lane] ^= value
            }
            for roundConstant in roundConstants {
                var column = [UInt64](repeating: 0, count: 5)
                for x in 0..<5 {
                    column[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20]
                }
                var delta = [UInt64](repeating: 0, count: 5)
                for x in 0..<5 {
                    delta[x] = column[(x + 4) % 5] ^ rotateLeft(column[(x + 1) % 5], 1)
                }
                for x in 0..<5 {
                    for y in 0..<5 { state[x + 5 * y] ^= delta[x] }
                }
                var mixed = [UInt64](repeating: 0, count: 25)
                for x in 0..<5 {
                    for y in 0..<5 {
                        mixed[y + 5 * ((2 * x + 3 * y) % 5)] = rotateLeft(state[x + 5 * y], rotationOffsets[x][y])
                    }
                }
                for x in 0..<5 {
                    for y in 0..<5 {
                        state[x + 5 * y] = mixed[x + 5 * y] ^ ((~mixed[(x + 1) % 5 + 5 * y]) & mixed[(x + 2) % 5 + 5 * y])
                    }
                }
                state[0] ^= roundConstant
            }
            blockStart += rate
        }

        var output: [UInt8] = []
        for lane in 0..<4 {
            var value = state[lane]
            for _ in 0..<8 {
                output.append(UInt8(truncatingIfNeeded: value))
                value >>= 8
            }
        }
        return output
    }

    private static func rotateLeft(_ value: UInt64, _ amount: Int) -> UInt64 {
        amount == 0 ? value : (value << amount) | (value >> (64 - amount))
    }
}

// MARK: - secp256k1 (Jacobian coordinates)

private struct JacobianPoint {
    var x: TronBigInt
    var y: TronBigInt
    var z: TronBigInt
    var isInfinity: Bool { z.isZero }
    static let infinity = JacobianPoint(x: TronBigInt(), y: TronBigInt(), z: TronBigInt())
}

enum Secp256k1 {
    static let p = TronBigInt(hex: "fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f")
    static let n = TronBigInt(hex: "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141")
    static let gx = TronBigInt(hex: "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")
    static let gy = TronBigInt(hex: "483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8")
    static let generator = JacobianPoint(x: gx, y: gy, z: TronBigInt(u64: 1))

    // Field arithmetic mod p.
    private static func addP(_ a: TronBigInt, _ b: TronBigInt) -> TronBigInt {
        TronBigInt.addMod(a, b, p)
    }

    private static func subP(_ a: TronBigInt, _ b: TronBigInt) -> TronBigInt {
        TronBigInt.subMod(a, b, p)
    }

    private static func mulP(_ a: TronBigInt, _ b: TronBigInt) -> TronBigInt {
        reduceP(TronBigInt.multiply(a, b))
    }

    /// Fast reduction mod p using 2^256 == 2^32 + 977 (mod p).
    static func reduceP(_ value: TronBigInt) -> TronBigInt {
        var limbs = value.limbs
        while limbs.count > 9 {
            let low = Array(limbs.prefix(8))
            let high = Array(limbs.dropFirst(8))
            var shifted: [UInt32] = [0] + high
            var product: [UInt32] = []
            var carry: UInt64 = 0
            for limb in high {
                let current = UInt64(limb) &* 977 &+ carry
                product.append(UInt32(truncatingIfNeeded: current))
                carry = current >> 32
            }
            if carry != 0 { product.append(UInt32(truncatingIfNeeded: carry)) }
            var accumulated = low
            accumulated = TronBigInt.addLimbs(accumulated, shifted)
            accumulated = TronBigInt.addLimbs(accumulated, product)
            limbs = accumulated
        }
        if limbs.count == 9 {
            let low = Array(limbs.prefix(8))
            let high = limbs[8]
            var shifted: [UInt32] = [0, high]
            let productValue = UInt64(high) &* 977
            var product = [UInt32(truncatingIfNeeded: productValue)]
            if productValue >> 32 != 0 { product.append(UInt32(truncatingIfNeeded: productValue >> 32)) }
            var accumulated = low
            accumulated = TronBigInt.addLimbs(accumulated, shifted)
            accumulated = TronBigInt.addLimbs(accumulated, product)
            limbs = accumulated
        }
        var result = TronBigInt(limbs)
        if TronBigInt.compare(result, p) >= 0 { result = TronBigInt.subtract(result, p) }
        if TronBigInt.compare(result, p) >= 0 { result = TronBigInt.subtract(result, p) }
        return result
    }

    static func double(_ point: JacobianPoint) -> JacobianPoint {
        if point.isInfinity || point.y.isZero { return .infinity }
        let a = mulP(point.x, point.x)
        let b = mulP(point.y, point.y)
        let c = mulP(b, b)
        let xPlusB = addP(point.x, b)
        let t = subP(mulP(xPlusB, xPlusB), addP(a, c))
        let d = addP(t, t)
        let e = addP(a, addP(a, a))
        let f = mulP(e, e)
        let x3 = subP(f, addP(d, d))
        var eightC = c
        eightC = addP(eightC, eightC)
        eightC = addP(eightC, eightC)
        eightC = addP(eightC, eightC)
        let y3 = subP(mulP(e, subP(d, x3)), eightC)
        let z3 = mulP(addP(point.y, point.y), point.z)
        return JacobianPoint(x: x3, y: y3, z: z3)
    }

    static func add(_ first: JacobianPoint, _ second: JacobianPoint) -> JacobianPoint {
        if first.isInfinity { return second }
        if second.isInfinity { return first }
        let z1z1 = mulP(first.z, first.z)
        let z2z2 = mulP(second.z, second.z)
        let u1 = mulP(first.x, z2z2)
        let u2 = mulP(second.x, z1z1)
        let s1 = mulP(first.y, mulP(second.z, z2z2))
        let s2 = mulP(second.y, mulP(first.z, z1z1))
        if u1 == u2 {
            return s1 == s2 ? double(first) : .infinity
        }
        let h = subP(u2, u1)
        let i = mulP(addP(h, h), addP(h, h))
        let j = mulP(h, i)
        let r = addP(subP(s2, s1), subP(s2, s1))
        let v = mulP(u1, i)
        let x3 = subP(subP(mulP(r, r), j), addP(v, v))
        let y3 = subP(mulP(r, subP(v, x3)), mulP(addP(s1, s1), j))
        let zSum = addP(first.z, second.z)
        let z3 = mulP(subP(subP(mulP(zSum, zSum), z1z1), z2z2), h)
        return JacobianPoint(x: x3, y: y3, z: z3)
    }

    /// MSB-first double-and-add scalar multiplication; returns affine coordinates.
    static func scalarMultiply(_ scalar: TronBigInt) -> (x: TronBigInt, y: TronBigInt) {
        precondition(!scalar.isZero && TronBigInt.compare(scalar, n) < 0, "scalar out of range")
        var point = JacobianPoint.infinity
        var started = false
        var index = scalar.bitCount - 1
        while index >= 0 {
            if started { point = double(point) }
            if scalar.bit(index) {
                point = add(point, generator)
                started = true
            }
            index -= 1
        }
        let inverseZ = TronBigInt.invMod(point.z, p)
        let inverseZ2 = mulP(inverseZ, inverseZ)
        let inverseZ3 = mulP(inverseZ2, inverseZ)
        return (mulP(point.x, inverseZ2), mulP(point.y, inverseZ3))
    }
}

// MARK: - TRON signer

struct BlockReference {
    let blockIDHex: String
    let expirationMs: Int64
    let timestampMs: Int64
}

struct BuiltTransaction {
    let rawHex: String
    let txid: String
    let signedHex: String
    let rawJSON: [String: Any]
    let signatureHex: String
}

enum TronSigner {
    static let usdtContractAddress = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
    static let trxFeeLimitSun: Int64 = 10_000_000
    static let trc20FeeLimitSun: Int64 = 50_000_000

    private static let base58Alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    // MARK: Helpers

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func unhex(_ string: String) -> [UInt8] {
        var output: [UInt8] = []
        let characters = Array(string)
        var index = 0
        while index + 1 < characters.count {
            let high = characters[index].hexDigitValue ?? 0
            let low = characters[index + 1].hexDigitValue ?? 0
            output.append(UInt8((high << 4) | low))
            index += 2
        }
        return output
    }

    private static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: Data(bytes)))
    }

    private static func doubleSha256(_ bytes: [UInt8]) -> [UInt8] {
        sha256(sha256(bytes))
    }

    static func parseKey(_ privateKeyHex: String) throws -> [UInt8] {
        let trimmed = privateKeyHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 64, trimmed.allSatisfy({ $0.isHexDigit }) else { throw TronSignerError.invalidKey }
        let key = unhex(trimmed)
        let scalar = TronBigInt(bytesBE: key)
        guard !scalar.isZero, TronBigInt.compare(scalar, Secp256k1.n) < 0 else { throw TronSignerError.invalidKey }
        return key
    }

    // MARK: Base58Check

    static func base58Encode(_ bytes: [UInt8]) -> String {
        var value = TronBigInt(bytesBE: bytes)
        var output = ""
        let fiftyEight = TronBigInt(u64: 58)
        while !value.isZero {
            let division = TronBigInt.divmod(value, fiftyEight)
            let remainder = Int(division.remainder.limbs.first ?? 0)
            output.append(base58Alphabet[remainder])
            value = division.quotient
        }
        for byte in bytes {
            if byte == 0 { output.append("1") } else { break }
        }
        return String(output.reversed())
    }

    static func base58Decode(_ text: String) -> [UInt8]? {
        var value = TronBigInt()
        let fiftyEight = TronBigInt(u64: 58)
        for character in text {
            guard let digit = base58Alphabet.firstIndex(of: character) else { return nil }
            value = TronBigInt.add(TronBigInt.multiply(value, fiftyEight), TronBigInt(u64: UInt64(digit)))
        }
        var bytes = value.bytesBE
        while bytes.first == 0 { bytes.removeFirst() }
        for character in text {
            if character == "1" { bytes.insert(0, at: 0) } else { break }
        }
        return bytes
    }

    /// Decodes a T... base58check address into its 21 raw bytes (0x41 + 20).
    static func decodeAddress(_ text: String) throws -> [UInt8] {
        guard let raw = base58Decode(text), raw.count == 25, raw[0] == 0x41 else {
            throw TronSignerError.invalidAddress(text)
        }
        let payload = Array(raw.prefix(21))
        let checksum = Array(raw.suffix(4))
        guard Array(doubleSha256(payload).prefix(4)).elementsEqual(checksum) else {
            throw TronSignerError.invalidAddress(text)
        }
        return payload
    }

    // MARK: Private key -> address

    /// Derives the 21 raw address bytes for a private key.
    static func addressBytes(privateKeyHex: String) throws -> [UInt8] {
        let key = try parseKey(privateKeyHex)
        let point = Secp256k1.scalarMultiply(TronBigInt(bytesBE: key))
        let digest = Keccak256.hash(point.x.bytes32BE() + point.y.bytes32BE())
        return [0x41] + Array(digest[12..<32])
    }

    /// Derives the T... base58check address for a private key.
    static func address(privateKeyHex: String) throws -> String {
        let payload = try addressBytes(privateKeyHex: privateKeyHex)
        return base58Encode(payload + Array(doubleSha256(payload).prefix(4)))
    }

    // MARK: RFC 6979 + ECDSA

    static func rfc6979K(key: [UInt8], z: TronBigInt) -> TronBigInt {
        var v = [UInt8](repeating: 0x01, count: 32)
        var k = [UInt8](repeating: 0x00, count: 32)
        let h1 = z.bytes32BE()

        func hmac(_ keyBytes: [UInt8], _ dataBytes: [UInt8]) -> [UInt8] {
            let mac = HMAC<SHA256>.authenticationCode(
                for: Data(dataBytes), using: SymmetricKey(data: Data(keyBytes)))
            return Array(mac)
        }

        k = hmac(k, v + [0x00] + key + h1)
        v = hmac(k, v)
        k = hmac(k, v + [0x01] + key + h1)
        v = hmac(k, v)
        while true {
            v = hmac(k, v)
            let candidate = TronBigInt(bytesBE: v)
            if !candidate.isZero && TronBigInt.compare(candidate, Secp256k1.n) < 0 { return candidate }
            k = hmac(k, v + [0x00])
            v = hmac(k, v)
        }
    }

    /// Deterministic ECDSA over secp256k1; low-s normalized; returns 64 bytes + recovery id.
    static func sign(key: [UInt8], digest: TronBigInt) throws -> (r: [UInt8], s: [UInt8], recid: UInt8) {
        let d = TronBigInt(bytesBE: key)
        let z = TronBigInt.divmod(digest, Secp256k1.n).remainder
        let k = rfc6979K(key: key, z: z)
        let point = Secp256k1.scalarMultiply(k)
        let r = TronBigInt.divmod(point.x, Secp256k1.n).remainder
        guard !r.isZero else { throw TronSignerError.signatureFailure }
        let kInverse = TronBigInt.invMod(k, Secp256k1.n)
        var s = TronBigInt.mulMod(
            kInverse,
            TronBigInt.addMod(z, TronBigInt.mulMod(r, d, Secp256k1.n), Secp256k1.n),
            Secp256k1.n)
        guard !s.isZero else { throw TronSignerError.signatureFailure }
        var recid: UInt8 = ((point.y.limbs.first ?? 0) & 1) == 1 ? 1 : 0
        if TronBigInt.compare(point.x, Secp256k1.n) >= 0 { recid |= 2 }
        let halfOrder = TronBigInt.shiftRightOne(Secp256k1.n)
        if TronBigInt.compare(s, halfOrder) > 0 {
            s = TronBigInt.subtract(Secp256k1.n, s)
            recid ^= 1
        }
        return (r.bytes32BE(), s.bytes32BE(), recid)
    }

    // MARK: Amount conversion

    static func sunAmount(_ amount: Decimal) throws -> Int64 {
        guard amount > 0 else { throw TronSignerError.invalidAmount("Amount must be greater than zero.") }
        var scaled = amount * Decimal(1_000_000)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled else {
            throw TronSignerError.invalidAmount("The amount exceeds the supported 6 decimal places.")
        }
        let number = rounded as NSDecimalNumber
        guard number.int64Value > 0, Decimal(number.int64Value) == rounded else {
            throw TronSignerError.invalidAmount("The amount is too large.")
        }
        return number.int64Value
    }

    static func baseUnits(_ amount: Decimal, decimals: Int) throws -> TronBigInt {
        guard amount > 0 else { throw TronSignerError.invalidAmount("Amount must be greater than zero.") }
        var scale = Decimal(1)
        for _ in 0..<max(0, decimals) { scale *= 10 }
        var scaled = amount * scale
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled else {
            throw TronSignerError.invalidAmount("The amount exceeds the supported \(decimals) decimal places.")
        }
        guard let big = TronBigInt(decimalString: (rounded as NSDecimalNumber).stringValue) else {
            throw TronSignerError.invalidAmount("The amount could not be converted.")
        }
        return big
    }

    // MARK: Transaction building

    private struct ProtoWriter {
        private(set) var data = Data()

        mutating func varint(_ value: UInt64) {
            var current = value
            while current >= 0x80 {
                data.append(UInt8(truncatingIfNeeded: current) | 0x80)
                current >>= 7
            }
            data.append(UInt8(truncatingIfNeeded: current))
        }

        mutating func intField(_ field: Int, _ value: UInt64) {
            varint(UInt64(field << 3))
            varint(value)
        }

        mutating func bytesField(_ field: Int, _ bytes: [UInt8]) {
            varint(UInt64((field << 3) | 2))
            varint(UInt64(bytes.count))
            data.append(contentsOf: bytes)
        }
    }

    private static func anyMessage(typeURL: String, value: [UInt8]) -> [UInt8] {
        var writer = ProtoWriter()
        writer.bytesField(1, Array(typeURL.utf8))
        writer.bytesField(2, value)
        return Array(writer.data)
    }

    private static func refParts(_ ref: BlockReference) throws -> ([UInt8], [UInt8]) {
        guard ref.blockIDHex.count == 64 else { throw TronSignerError.invalidAddress("block reference") }
        let blockID = Array(ref.blockIDHex)
        return (unhex(String(blockID[12..<16])), unhex(String(blockID[16..<32])))
    }

    private static func buildRaw(ref: BlockReference, contract: [UInt8], feeLimitSun: Int64) throws -> [UInt8] {
        let (refBytes, refHash) = try refParts(ref)
        var writer = ProtoWriter()
        writer.bytesField(1, refBytes)
        writer.bytesField(4, refHash)
        writer.intField(8, UInt64(bitPattern: ref.expirationMs))
        writer.bytesField(11, contract)
        writer.intField(14, UInt64(bitPattern: ref.timestampMs))
        if feeLimitSun > 0 { writer.intField(18, UInt64(bitPattern: feeLimitSun)) }
        return Array(writer.data)
    }

    private static func rawJSON(
        ref: BlockReference,
        contractType: String,
        typeURL: String,
        value: [String: Any],
        feeLimitSun: Int64
    ) throws -> [String: Any] {
        let (refBytes, refHash) = try refParts(ref)
        var raw: [String: Any] = [
            "ref_block_bytes": hex(refBytes),
            "ref_block_hash": hex(refHash),
            "expiration": ref.expirationMs,
            "contract": [["type": contractType, "parameter": ["type_url": typeURL, "value": value]]],
            "timestamp": ref.timestampMs,
        ]
        if feeLimitSun > 0 { raw["fee_limit"] = feeLimitSun }
        return raw
    }

    private static func signAndWrap(key: [UInt8], raw: [UInt8], rawJSON: [String: Any]) throws -> BuiltTransaction {
        let digest = sha256(raw)
        let signature = try sign(key: key, digest: TronBigInt(bytesBE: digest))
        let signatureBytes = signature.r + signature.s + [signature.recid]
        var transaction = ProtoWriter()
        transaction.bytesField(1, raw)
        transaction.bytesField(2, signatureBytes)
        return BuiltTransaction(
            rawHex: hex(raw),
            txid: hex(digest),
            signedHex: hex(Array(transaction.data)),
            rawJSON: rawJSON,
            signatureHex: hex(signatureBytes))
    }

    static func buildTRXTransfer(
        privateKeyHex: String,
        toAddress: String,
        amountSun: Int64,
        ref: BlockReference
    ) throws -> BuiltTransaction {
        let key = try parseKey(privateKeyHex)
        let owner = try addressBytes(privateKeyHex: privateKeyHex)
        let destination = try decodeAddress(toAddress)
        guard amountSun > 0 else { throw TronSignerError.invalidAmount("Amount must be greater than zero.") }
        var contract = ProtoWriter()
        contract.bytesField(1, owner)
        contract.bytesField(2, destination)
        contract.intField(3, UInt64(bitPattern: amountSun))
        var outer = ProtoWriter()
        outer.intField(1, 1)
        outer.bytesField(2, anyMessage(
            typeURL: "type.googleapis.com/protocol.TransferContract", value: Array(contract.data)))
        let raw = try buildRaw(ref: ref, contract: Array(outer.data), feeLimitSun: trxFeeLimitSun)
        let json = try rawJSON(
            ref: ref,
            contractType: "TransferContract",
            typeURL: "type.googleapis.com/protocol.TransferContract",
            value: ["owner_address": hex(owner), "to_address": hex(destination), "amount": amountSun],
            feeLimitSun: trxFeeLimitSun)
        return try signAndWrap(key: key, raw: raw, rawJSON: json)
    }

    static func buildTRC20Transfer(
        privateKeyHex: String,
        contractAddress: String,
        toAddress: String,
        amountBaseUnits: TronBigInt,
        ref: BlockReference
    ) throws -> BuiltTransaction {
        let key = try parseKey(privateKeyHex)
        let owner = try addressBytes(privateKeyHex: privateKeyHex)
        let destination = try decodeAddress(toAddress)
        let contract = try decodeAddress(contractAddress)
        guard !amountBaseUnits.isZero else { throw TronSignerError.invalidAmount("Amount must be greater than zero.") }
        let data = [0xa9, 0x05, 0x9c, 0xbb]
            + [UInt8](repeating: 0x00, count: 12)
            + Array(destination.dropFirst())
            + amountBaseUnits.bytes32BE()
        var inner = ProtoWriter()
        inner.bytesField(1, owner)
        inner.bytesField(2, contract)
        inner.bytesField(4, data)
        var outer = ProtoWriter()
        outer.intField(1, 31)
        outer.bytesField(2, anyMessage(
            typeURL: "type.googleapis.com/protocol.TriggerSmartContract", value: Array(inner.data)))
        let raw = try buildRaw(ref: ref, contract: Array(outer.data), feeLimitSun: trc20FeeLimitSun)
        let json = try rawJSON(
            ref: ref,
            contractType: "TriggerSmartContract",
            typeURL: "type.googleapis.com/protocol.TriggerSmartContract",
            value: ["owner_address": hex(owner), "contract_address": hex(contract), "data": hex(data)],
            feeLimitSun: trc20FeeLimitSun)
        return try signAndWrap(key: key, raw: raw, rawJSON: json)
    }
}

// MARK: - Self-test (chain-verified vectors)

#if DEBUG
extension TronSigner {
    /// Vectors generated by Tools/verify_tron_signer.py and validated against
    /// the live chain plus libsecp256k1 (coincurve).
    static func runSelfTest() {
        var failures: [String] = []
        func expect(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        expect("keccak-empty", hex(Keccak256.hash([]))
            == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        expect("keccak-abc", hex(Keccak256.hash(Array("abc".utf8)))
            == "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")

        let keyOne = String(repeating: "0", count: 63) + "1"
        expect("address-1", (try? address(privateKeyHex: keyOne)) == "TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC")
        expect("address-123456789",
               (try? address(privateKeyHex: String(format: "%064llx", UInt64(123456789)))) == "TMRyaDePk63uo2MGLJAj3Ki71AfA7CLT4w")

        let fixedKey = "9c8b1f6d3e7a2b5c4d8e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e"
        expect("address-fixed", (try? address(privateKeyHex: fixedKey)) == "TALxLgri9eHHDyYicNkWreWt9REKQ5eV4a")

        if let key = try? parseKey(keyOne) {
            let message = sha256(Array("LapTimer-TRON-self-test".utf8))
            if let signature = try? sign(key: key, digest: TronBigInt(bytesBE: message)) {
                expect("rfc6979-r", hex(signature.r) == "e61be4ff45f2585172b6dc96c7b0de19af81c8c05409fff750daa8ea174edee9")
                expect("rfc6979-s", hex(signature.s) == "0ddbde08df77866cc0bc7a67882d5118a709b315a2c7100a1c6b7f344db28b25")
                expect("rfc6979-recid", signature.recid == 1)
            } else {
                expect("rfc6979-sign", false)
            }
        } else {
            expect("rfc6979-key", false)
        }

        let ref = BlockReference(
            blockIDHex: "00000000053cbd81c4fe417457cccfdaa34b223c74e4bff32fcf6df6c7195642",
            expirationMs: 1794274092000,
            timestampMs: 1794274033000)
        let destination = "TMRyaDePk63uo2MGLJAj3Ki71AfA7CLT4w"

        if let trx = try? buildTRXTransfer(privateKeyHex: fixedKey, toAddress: destination, amountSun: 1_500_000, ref: ref) {
            expect("trx-txid", trx.txid == "e2e22f89687dda148c256affa6b368652ba9375a13a81e9a82e24c49ff23fb09")
            expect("trx-signed", trx.signedHex
                == "0a8b010a02bd812208c4fe417457cccfda40e0c7c7989c345a67080112630a2d747970652e676f6f676c65617069732e636f6d2f70726f746f636f6c2e5472616e73666572436f6e747261637412320a1541041ce98c5d73a37f2bbf61ee5d2a148ce07f72de1215417db967bcf885c8ae4bbfdb5ffff5d9ebf96aa0ed18e0c65b70e8fac3989c34900180ade2041241eb8a5ed66e5ac113b42993433c2f8e35b8247160c18ce43aa5e30a7cc3c0d2e12291038aacc51693b7a803eec671b3c51e115015eca7a0c55285b205997ee40401")
        } else {
            expect("trx-build", false)
        }

        if let usdt = try? buildTRC20Transfer(
            privateKeyHex: fixedKey,
            contractAddress: usdtContractAddress,
            toAddress: destination,
            amountBaseUnits: TronBigInt(u64: 12_340_000),
            ref: ref) {
            expect("usdt-txid", usdt.txid == "161f5c90da3db042efafd5752bca771577fd1bc7bc2a0fbb656381880bf9abd1")
            expect("usdt-signed", usdt.signedHex
                == "0ad3010a02bd812208c4fe417457cccfda40e0c7c7989c345aae01081f12a9010a31747970652e676f6f676c65617069732e636f6d2f70726f746f636f6c2e54726967676572536d617274436f6e747261637412740a1541041ce98c5d73a37f2bbf61ee5d2a148ce07f72de121541a614f803b6fd780986a42c78ec9c7f77e6ded13c2244a9059cbb0000000000000000000000007db967bcf885c8ae4bbfdb5ffff5d9ebf96aa0ed0000000000000000000000000000000000000000000000000000000000bc4b2070e8fac3989c34900180e1eb171241214fbdf51b87fcd626030a09b72d2c4e595e50429a3edc92f1da86c66b5d6bd0784f3364c8b5f4b76fb1bcd6913c4fa9551fde3d2b6eb3724a465243660164d300")
        } else {
            expect("usdt-build", false)
        }

        if failures.isEmpty {
            print("[TronSigner] self-test passed")
        } else {
            assertionFailure("[TronSigner] self-test failures: \(failures.joined(separator: ", "))")
        }
    }
}
#endif
