#!/usr/bin/env python3
"""TronSigner 的 Python 算法参考实现，用于校验数学结果和固定向量。

这不是 Swift 执行测试，不能验证 Swift 的构造函数、数组边界或优化行为。
曾因 BI.u64 自动归一化而漏掉 Swift 的高位零问题；必须同时运行
Tests/TronSignerRuntimeTests.swift 中的真实 Swift 回归测试。
"""
import hashlib
import hmac

MASK32 = (1 << 32) - 1

P_HEX = "fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f"
N_HEX = "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141"
GX_HEX = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
GY_HEX = "483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8"


class BI:
    """Mirror of TronBigInt: little-endian UInt32 limbs, no trailing zeros."""

    __slots__ = ("limbs",)

    def __init__(self, limbs=None):
        value = list(limbs) if limbs else []
        while value and value[-1] == 0:
            value.pop()
        self.limbs = value

    @staticmethod
    def u64(v):
        return BI([v & MASK32, v >> 32] if v else [])

    @staticmethod
    def from_hex(s):
        return BI.from_bytes_be(bytes.fromhex(s))

    @staticmethod
    def from_bytes_be(raw):
        result = []
        index = len(raw)
        while index > 0:
            limb = 0
            start = max(0, index - 4)
            for position in range(start, index):
                limb = (limb << 8) | raw[position]
            result.append(limb)
            index = start
        return BI(result)

    @staticmethod
    def from_decimal(s):
        result = BI()
        ten = BI.u64(10)
        for ch in s:
            result = BI.add(BI.multiply(result, ten), BI.u64(int(ch)))
        return result

    def is_zero(self):
        return not self.limbs

    def bit_count(self):
        if not self.limbs:
            return 0
        top = self.limbs[-1]
        return (len(self.limbs) - 1) * 32 + top.bit_length()

    def bit(self, index):
        limb = index // 32
        if limb >= len(self.limbs):
            return False
        return ((self.limbs[limb] >> (index % 32)) & 1) == 1

    def bytes_be(self):
        out = []
        for limb in reversed(self.limbs):
            v = limb
            for _ in range(4):
                out.append((v >> 24) & 0xFF)
                v = (v << 8) & MASK32
        return bytes(out)

    def bytes32_be(self):
        raw = self.bytes_be()
        if len(raw) > 32:
            raw = raw[-32:]
        return b"\x00" * (32 - len(raw)) + raw

    @staticmethod
    def compare(a, b):
        if len(a.limbs) != len(b.limbs):
            return -1 if len(a.limbs) < len(b.limbs) else 1
        for i in range(len(a.limbs) - 1, -1, -1):
            if a.limbs[i] != b.limbs[i]:
                return -1 if a.limbs[i] < b.limbs[i] else 1
        return 0

    @staticmethod
    def add(a, b):
        return BI(BI.add_limbs(a.limbs, b.limbs))

    @staticmethod
    def add_limbs(a, b):
        out = []
        carry = 0
        for i in range(max(len(a), len(b))):
            s = (a[i] if i < len(a) else 0) + (b[i] if i < len(b) else 0) + carry
            out.append(s & MASK32)
            carry = s >> 32
        if carry:
            out.append(carry)
        return out

    @staticmethod
    def subtract(a, b):  # requires a >= b
        out = []
        borrow = 0
        for i in range(len(a.limbs)):
            upper = a.limbs[i]
            lower = (b.limbs[i] if i < len(b.limbs) else 0) + borrow
            if upper >= lower:
                out.append(upper - lower)
                borrow = 0
            else:
                out.append((upper + (1 << 32) - lower) & MASK32)
                borrow = 1
        return BI(out)

    @staticmethod
    def multiply(a, b):
        out = [0] * (len(a.limbs) + len(b.limbs))
        for i in range(len(a.limbs)):
            carry = 0
            ai = a.limbs[i]
            for j in range(len(b.limbs)):
                cur = out[i + j] + ai * b.limbs[j] + carry
                out[i + j] = cur & MASK32
                carry = cur >> 32
            k = i + len(b.limbs)
            while carry:
                cur = out[k] + carry
                out[k] = cur & MASK32
                carry = cur >> 32
                k += 1
        return BI(out)

    @staticmethod
    def shift_left_one(a):
        out = [0] * (len(a.limbs) + 1)
        for i in range(len(a.limbs)):
            out[i] = ((a.limbs[i] << 1) | (a.limbs[i - 1] >> 31 if i > 0 else 0)) & MASK32
        if a.limbs:
            out[len(a.limbs)] = a.limbs[-1] >> 31
        return BI(out)

    @staticmethod
    def shift_right_one(a):
        out = [0] * len(a.limbs)
        for i in range(len(a.limbs) - 1, -1, -1):
            out[i] = a.limbs[i] >> 1
            if i + 1 < len(a.limbs):
                out[i] |= (a.limbs[i + 1] & 1) << 31
        return BI(out)

    @staticmethod
    def divmod(a, b):
        assert not b.is_zero()
        if BI.compare(a, b) < 0:
            return BI(), a
        remainder = BI()
        quotient = [0] * ((a.bit_count() + 31) // 32)
        for index in range(a.bit_count() - 1, -1, -1):
            remainder = BI.shift_left_one(remainder)
            if a.bit(index):
                if remainder.is_zero():
                    remainder.limbs = [1]
                else:
                    remainder.limbs[0] |= 1
            if BI.compare(remainder, b) >= 0:
                remainder = BI.subtract(remainder, b)
                quotient[index // 32] |= 1 << (index % 32)
        return BI(quotient), remainder

    @staticmethod
    def add_mod(a, b, m):
        s = BI.add(a, b)
        return BI.subtract(s, m) if BI.compare(s, m) >= 0 else s

    @staticmethod
    def sub_mod(a, b, m):
        return BI.subtract(a, b) if BI.compare(a, b) >= 0 else BI.add(BI.subtract(m, b), a)

    @staticmethod
    def mul_mod(a, b, m):
        return BI.divmod(BI.multiply(a, b), m)[1]

    @staticmethod
    def pow_mod(base, exponent, modulus):
        result = BI.u64(1)
        factor = base
        for index in range(exponent.bit_count()):
            if exponent.bit(index):
                result = BI.mul_mod(result, factor, modulus)
            factor = BI.mul_mod(factor, factor, modulus)
        return result

    @staticmethod
    def inv_mod(a, modulus):
        return BI.pow_mod(a, BI.subtract(modulus, BI.u64(2)), modulus)


P = BI.from_hex(P_HEX)
N = BI.from_hex(N_HEX)
GX = BI.from_hex(GX_HEX)
GY = BI.from_hex(GY_HEX)


def reduce_p(value: BI) -> BI:
    """Mirror of Secp256k1.reduceP (limb folding with 2^256 == 2^32 + 977)."""
    limbs = value.limbs[:]
    while len(limbs) > 9:
        low = limbs[:8]
        high = limbs[8:]
        shifted = [0] + high
        product = []
        carry = 0
        for limb in high:
            cur = limb * 977 + carry
            product.append(cur & MASK32)
            carry = cur >> 32
        if carry:
            product.append(carry)
        accumulated = low
        accumulated = BI.add_limbs(accumulated, shifted)
        accumulated = BI.add_limbs(accumulated, product)
        limbs = accumulated
    if len(limbs) == 9:
        low = limbs[:8]
        high = limbs[8]
        shifted = [0, high]
        product_value = high * 977
        product = [product_value & MASK32]
        if product_value >> 32:
            product.append(product_value >> 32)
        accumulated = low
        accumulated = BI.add_limbs(accumulated, shifted)
        accumulated = BI.add_limbs(accumulated, product)
        limbs = accumulated
    result = BI(limbs)
    if BI.compare(result, P) >= 0:
        result = BI.subtract(result, P)
    if BI.compare(result, P) >= 0:
        result = BI.subtract(result, P)
    return result


def add_p(a, b):
    return BI.add_mod(a, b, P)


def sub_p(a, b):
    return BI.sub_mod(a, b, P)


def mul_p(a, b):
    return reduce_p(BI.multiply(a, b))


def jdouble(pt):
    x1, y1, z1 = pt
    if z1.is_zero() or y1.is_zero():
        return (BI(), BI(), BI())
    a = mul_p(x1, x1)
    b = mul_p(y1, y1)
    c = mul_p(b, b)
    xpb = add_p(x1, b)
    t = sub_p(mul_p(xpb, xpb), add_p(a, c))
    d = add_p(t, t)
    e = add_p(a, add_p(a, a))
    f = mul_p(e, e)
    x3 = sub_p(f, add_p(d, d))
    eight_c = add_p(add_p(add_p(c, c), add_p(c, c)), add_p(add_p(c, c), add_p(c, c)))
    y3 = sub_p(mul_p(e, sub_p(d, x3)), eight_c)
    z3 = mul_p(add_p(y1, y1), z1)
    return (x3, y3, z3)


def jadd(fst, snd):
    x1, y1, z1 = fst
    x2, y2, z2 = snd
    if z1.is_zero():
        return snd
    if z2.is_zero():
        return fst
    z1z1 = mul_p(z1, z1)
    z2z2 = mul_p(z2, z2)
    u1 = mul_p(x1, z2z2)
    u2 = mul_p(x2, z1z1)
    s1 = mul_p(y1, mul_p(z2, z2z2))
    s2 = mul_p(y2, mul_p(z1, z1z1))
    if BI.compare(u1, u2) == 0:
        return jdouble(fst) if BI.compare(s1, s2) == 0 else (BI(), BI(), BI())
    h = sub_p(u2, u1)
    i = mul_p(add_p(h, h), add_p(h, h))
    j = mul_p(h, i)
    r = add_p(sub_p(s2, s1), sub_p(s2, s1))
    v = mul_p(u1, i)
    x3 = sub_p(sub_p(mul_p(r, r), j), add_p(v, v))
    y3 = sub_p(mul_p(r, sub_p(v, x3)), mul_p(add_p(s1, s1), j))
    zsum = add_p(z1, z2)
    z3 = mul_p(sub_p(sub_p(mul_p(zsum, zsum), z1z1), z2z2), h)
    return (x3, y3, z3)


def scalar_multiply(scalar: BI):
    assert not scalar.is_zero() and BI.compare(scalar, N) < 0
    point = (BI(), BI(), BI())
    started = False
    for index in range(scalar.bit_count() - 1, -1, -1):
        if started:
            point = jdouble(point)
        if scalar.bit(index):
            point = jadd(point, (GX, GY, BI.u64(1)))
            started = True
    x, y, z = point
    inv_z = BI.inv_mod(z, P)
    inv_z2 = mul_p(inv_z, inv_z)
    inv_z3 = mul_p(inv_z2, inv_z)
    return mul_p(x, inv_z2), mul_p(y, inv_z3)


def keccak256(data: bytes) -> bytes:
    RC = [0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
          0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
          0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
          0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
          0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
          0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008]
    ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61],
           [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
    MASK = (1 << 64) - 1

    def rotl(x, n):
        return ((x << n) | (x >> (64 - n))) & MASK

    rate = 136
    padded = bytearray(data)
    padded.append(0x01)
    while len(padded) % rate != rate - 1:
        padded.append(0)
    padded.append(0x80)
    state = [0] * 25
    for bs in range(0, len(padded), rate):
        block = padded[bs:bs + rate]
        for lane in range(rate // 8):
            value = 0
            for byte in range(8):
                value |= block[lane * 8 + byte] << (byte * 8)
            state[lane] ^= value
        for rc in RC:
            column = [state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20] for x in range(5)]
            delta = [column[(x + 4) % 5] ^ rotl(column[(x + 1) % 5], 1) for x in range(5)]
            for x in range(5):
                for y in range(5):
                    state[x + 5 * y] ^= delta[x]
            mixed = [0] * 25
            for x in range(5):
                for y in range(5):
                    mixed[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(state[x + 5 * y], ROT[x][y])
            for x in range(5):
                for y in range(5):
                    state[x + 5 * y] = mixed[x + 5 * y] ^ ((~mixed[(x + 1) % 5 + 5 * y]) & mixed[(x + 2) % 5 + 5 * y])
            state[0] ^= rc
    return b"".join((state[i] & MASK).to_bytes(8, "little") for i in range(4))


B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def base58_encode(raw: bytes) -> str:
    value = BI.from_bytes_be(raw)
    out = ""
    fifty_eight = BI.u64(58)
    while not value.is_zero():
        q, r = BI.divmod(value, fifty_eight)
        out += B58[r.limbs[0] if r.limbs else 0]
        value = q
    for byte in raw:
        if byte == 0:
            out += "1"
        else:
            break
    return out[::-1]


def base58_decode(text: str):
    value = BI()
    fifty_eight = BI.u64(58)
    for ch in text:
        digit = B58.index(ch)
        value = BI.add(BI.multiply(value, fifty_eight), BI.u64(digit))
    raw = bytearray(value.bytes_be())
    while raw and raw[0] == 0:
        del raw[0]
    for ch in text:
        if ch == "1":
            raw.insert(0, 0)
        else:
            break
    return bytes(raw)


def decode_address(text: str) -> bytes:
    raw = base58_decode(text)
    assert len(raw) == 25 and raw[0] == 0x41
    payload = raw[:21]
    checksum = raw[21:]
    assert hashlib.sha256(hashlib.sha256(payload).digest()).digest()[:4] == checksum
    return payload


def address_bytes(priv_key: bytes) -> bytes:
    d = BI.from_bytes_be(priv_key)
    x, y = scalar_multiply(d)
    digest = keccak256(x.bytes32_be() + y.bytes32_be())
    return b"\x41" + digest[12:32]


def address(priv_key: bytes) -> str:
    payload = address_bytes(priv_key)
    checksum = hashlib.sha256(hashlib.sha256(payload).digest()).digest()[:4]
    return base58_encode(payload + checksum)


def rfc6979_k(key: bytes, z: BI) -> BI:
    v = b"\x01" * 32
    k = b"\x00" * 32
    h1 = z.bytes32_be()

    def hmac_fn(key_bytes, data_bytes):
        return hmac.new(key_bytes, data_bytes, hashlib.sha256).digest()

    k = hmac_fn(k, v + b"\x00" + key + h1)
    v = hmac_fn(k, v)
    k = hmac_fn(k, v + b"\x01" + key + h1)
    v = hmac_fn(k, v)
    while True:
        v = hmac_fn(k, v)
        candidate = BI.from_bytes_be(v)
        if not candidate.is_zero() and BI.compare(candidate, N) < 0:
            return candidate
        k = hmac_fn(k, v + b"\x00")
        v = hmac_fn(k, v)


def sign(key: bytes, digest: BI):
    d = BI.from_bytes_be(key)
    z = BI.divmod(digest, N)[1]
    k = rfc6979_k(key, z)
    px, py = scalar_multiply(k)
    r = BI.divmod(px, N)[1]
    assert not r.is_zero()
    k_inv = BI.inv_mod(k, N)
    s = BI.mul_mod(k_inv, BI.add_mod(z, BI.mul_mod(r, d, N), N), N)
    assert not s.is_zero()
    recid = 1 if (py.limbs[0] if py.limbs else 0) & 1 else 0
    if BI.compare(px, N) >= 0:
        recid |= 2
    half = BI.shift_right_one(N)
    if BI.compare(s, half) > 0:
        s = BI.subtract(N, s)
        recid ^= 1
    return r.bytes32_be(), s.bytes32_be(), recid


def pv_varint(v):
    out = bytearray()
    while v >= 0x80:
        out.append((v & 0x7F) | 0x80)
        v >>= 7
    out.append(v)
    return bytes(out)


def pv_bytes(field, data):
    return pv_varint((field << 3) | 2) + pv_varint(len(data)) + data


def pv_int(field, v):
    return pv_varint(field << 3) + pv_varint(v & ((1 << 64) - 1))


def any_message(type_url, value):
    return pv_bytes(1, type_url.encode()) + pv_bytes(2, value)


def build_raw(ref_block_bytes, ref_block_hash, expiration, timestamp, contract, fee_limit):
    out = pv_bytes(1, ref_block_bytes)
    out += pv_bytes(4, ref_block_hash)
    out += pv_int(8, expiration)
    out += pv_bytes(11, contract)
    out += pv_int(14, timestamp)
    if fee_limit > 0:
        out += pv_int(18, fee_limit)
    return out


def sign_and_wrap(key, raw):
    digest = hashlib.sha256(raw).digest()
    r, s, recid = sign(key, BI.from_bytes_be(digest))
    tx = pv_bytes(1, raw) + pv_bytes(2, r + s + bytes([recid]))
    return digest.hex(), tx.hex()


def build_trx(priv, to_address, amount_sun, ref):
    owner = address_bytes(priv)
    dest = decode_address(to_address)
    contract = pv_bytes(1, owner) + pv_bytes(2, dest) + pv_int(3, amount_sun)
    outer = pv_int(1, 1) + pv_bytes(2, any_message("type.googleapis.com/protocol.TransferContract", contract))
    raw = build_raw(ref[0], ref[1], ref[2], ref[3], outer, 10_000_000)
    return sign_and_wrap(priv, raw)


def build_trc20(priv, contract_address, to_address, amount_base: BI, ref):
    owner = address_bytes(priv)
    dest = decode_address(to_address)
    contract_bytes = decode_address(contract_address)
    data = bytes.fromhex("a9059cbb") + b"\x00" * 12 + dest[1:] + amount_base.bytes32_be()
    inner = pv_bytes(1, owner) + pv_bytes(2, contract_bytes) + pv_bytes(4, data)
    outer = pv_int(1, 31) + pv_bytes(2, any_message("type.googleapis.com/protocol.TriggerSmartContract", inner))
    raw = build_raw(ref[0], ref[1], ref[2], ref[3], outer, 50_000_000)
    return sign_and_wrap(priv, raw)


def main():
    failures = []

    def check(name, ok):
        print(("[PASS] " if ok else "[FAIL] ") + name)
        if not ok:
            failures.append(name)

    check("keccak-empty", keccak256(b"").hex() == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
    check("keccak-abc", keccak256(b"abc").hex() == "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")

    x2, y2 = scalar_multiply(BI.u64(2))
    check("2*G", x2.bytes32_be().hex() == "c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
          and y2.bytes32_be().hex() == "1ae168fea63dc339a3c58419466ceaeef7f632653266d0e1236431a950cfe52a")
    x3, y3 = scalar_multiply(BI.u64(3))
    s2 = jadd((x2, y2, BI.u64(1)), (GX, GY, BI.u64(1)))
    inv = BI.inv_mod(s2[2], P)
    inv2 = mul_p(inv, inv)
    inv3 = mul_p(inv2, inv)
    ax = mul_p(s2[0], inv2)
    ay = mul_p(s2[1], inv3)
    check("3*G == 2*G + G", BI.compare(ax, x3) == 0 and BI.compare(ay, y3) == 0)

    key_one = b"\x00" * 31 + b"\x01"
    check("address-1", address(key_one) == "TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC")
    check("address-123456789", address((123456789).to_bytes(32, "big")) == "TMRyaDePk63uo2MGLJAj3Ki71AfA7CLT4w")
    fixed_key = bytes.fromhex("9c8b1f6d3e7a2b5c4d8e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e")
    check("address-fixed", address(fixed_key) == "TALxLgri9eHHDyYicNkWreWt9REKQ5eV4a")

    message = hashlib.sha256(b"LapTimer-TRON-self-test").digest()
    r, s, recid = sign(key_one, BI.from_bytes_be(message))
    check("rfc6979-r", r.hex() == "e61be4ff45f2585172b6dc96c7b0de19af81c8c05409fff750daa8ea174edee9")
    check("rfc6979-s", s.hex() == "0ddbde08df77866cc0bc7a67882d5118a709b315a2c7100a1c6b7f344db28b25")
    check("rfc6979-recid", recid == 1)

    ref = (bytes.fromhex("bd81"), bytes.fromhex("c4fe417457cccfda"), 1794274092000, 1794274033000)
    dest = "TMRyaDePk63uo2MGLJAj3Ki71AfA7CLT4w"
    txid, signed = build_trx(fixed_key, dest, 1_500_000, ref)
    check("trx-txid", txid == "e2e22f89687dda148c256affa6b368652ba9375a13a81e9a82e24c49ff23fb09")
    check("trx-signed", signed
          == "0a8b010a02bd812208c4fe417457cccfda40e0c7c7989c345a67080112630a2d747970652e676f6f676c65617069732e636f6d2f70726f746f636f6c2e5472616e73666572436f6e747261637412320a1541041ce98c5d73a37f2bbf61ee5d2a148ce07f72de1215417db967bcf885c8ae4bbfdb5ffff5d9ebf96aa0ed18e0c65b70e8fac3989c34900180ade2041241eb8a5ed66e5ac113b42993433c2f8e35b8247160c18ce43aa5e30a7cc3c0d2e12291038aacc51693b7a803eec671b3c51e115015eca7a0c55285b205997ee40401")
    txid, signed = build_trc20(fixed_key, "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t", dest, BI.u64(12_340_000), ref)
    check("usdt-txid", txid == "161f5c90da3db042efafd5752bca771577fd1bc7bc2a0fbb656381880bf9abd1")
    check("usdt-signed", signed
          == "0ad3010a02bd812208c4fe417457cccfda40e0c7c7989c345aae01081f12a9010a31747970652e676f6f676c65617069732e636f6d2f70726f746f636f6c2e54726967676572536d617274436f6e747261637412740a1541041ce98c5d73a37f2bbf61ee5d2a148ce07f72de121541a614f803b6fd780986a42c78ec9c7f77e6ded13c2244a9059cbb0000000000000000000000007db967bcf885c8ae4bbfdb5ffff5d9ebf96aa0ed0000000000000000000000000000000000000000000000000000000000bc4b2070e8fac3989c34900180e1eb171241214fbdf51b87fcd626030a09b72d2c4e595e50429a3edc92f1da86c66b5d6bd0784f3364c8b5f4b76fb1bcd6913c4fa9551fde3d2b6eb3724a465243660164d300")

    # limb-level differential: fast reduction vs native modulo on random products
    import random
    random.seed(99)
    reduce_ok = True
    for _ in range(5000):
        a = BI.from_bytes_be(random.getrandbits(256).to_bytes(32, "big"))
        b = BI.from_bytes_be(random.getrandbits(256).to_bytes(32, "big"))
        c = BI.multiply(a, b)
        native = int.from_bytes(c.bytes_be(), "big") % int.from_bytes(P.bytes_be(), "big")
        got = reduce_p(c)
        if got.bytes_be() != native.to_bytes(32, "big"):
            reduce_ok = False
            break
    check("reduceP differential (5000 products)", reduce_ok)

    if failures:
        print(f"{len(failures)} FAILURES: {failures}")
        return 1
    print("MIRROR: ALL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
