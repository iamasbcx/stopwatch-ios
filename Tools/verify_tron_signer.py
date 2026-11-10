#!/usr/bin/env python3
"""Ground-truth verification for Sources/TronSigner.swift.

Validates the pure-Swift plan against:
  1. well-known Keccak-256 test vectors (little-endian lane convention)
  2. secp256k1 curve constants and 2*G
  3. REAL on-chain TRON transactions (parse -> verify signature -> recover
     address, and byte-level protobuf comparison)
  4. coincurve (libsecp256k1 bindings) cross-checks for ECDSA
  5. builds TRX + USDT transactions and prints Swift self-test vectors
"""
import hashlib
import hmac
import json
import time
import urllib.request

TRONGRID = "https://api.trongrid.io"
USDT = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

def _get(path):
    req = urllib.request.Request(TRONGRID + path, headers={"Accept": "application/json", "User-Agent": "verify-tron"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)

def _post(path, body):
    req = urllib.request.Request(TRONGRID + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", "Accept": "application/json", "User-Agent": "verify-tron"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)

# ---------------------------------------------------------------------------
# Keccak-256. Lane convention: little-endian (XKCP reference load64).
# ---------------------------------------------------------------------------

_KECCAK_ROUNDS = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]
_KECCAK_ROT = [
    [0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61],
    [28, 55, 25, 21, 56], [27, 20, 39, 8, 14],
]
_MASK = (1 << 64) - 1


def _rotl(x, n):
    return ((x << n) | (x >> (64 - n))) & _MASK


def keccak256(data: bytes) -> bytes:
    rate = 136
    padded = bytearray(data)
    padded.append(0x01)
    while len(padded) % rate != rate - 1:
        padded.append(0x00)
    padded.append(0x80)

    state = [0] * 25
    for block_start in range(0, len(padded), rate):
        block = padded[block_start:block_start + rate]
        for i in range(rate // 8):
            state[i] ^= int.from_bytes(block[i * 8:i * 8 + 8], "little")
        for rnd in _KECCAK_ROUNDS:
            c = [state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20] for x in range(5)]
            d = [c[(x - 1) % 5] ^ _rotl(c[(x + 1) % 5], 1) for x in range(5)]
            for x in range(5):
                for y in range(5):
                    state[x + 5 * y] ^= d[x]
            b = [0] * 25
            for x in range(5):
                for y in range(5):
                    b[y + 5 * ((2 * x + 3 * y) % 5)] = _rotl(state[x + 5 * y], _KECCAK_ROT[x][y])
            for x in range(5):
                for y in range(5):
                    state[x + 5 * y] = b[x + 5 * y] ^ ((~b[(x + 1) % 5 + 5 * y]) & b[(x + 2) % 5 + 5 * y])
            state[0] ^= rnd
    return b"".join(state[i].to_bytes(8, "little") for i in range(4))


# ---------------------------------------------------------------------------
# secp256k1 (Jacobian coordinates; formulas mirrored 1:1 by TronSigner.swift)
# ---------------------------------------------------------------------------

P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
GY = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8


def _inv(a, m):
    return pow(a, m - 2, m)


def _madd(a, b):
    r = a + b
    return r - P if r >= P else r


def _msub(a, b):
    r = a - b
    return r + P if r < 0 else r


def _mmul(a, b):
    return (a * b) % P


def _jdouble(X1, Y1, Z1):
    if Z1 == 0 or Y1 == 0:
        return (0, 0, 0)
    A = _mmul(X1, X1)
    B = _mmul(Y1, Y1)
    C = _mmul(B, B)
    t = _mmul(_madd(X1, B), _madd(X1, B))
    t = _msub(t, _madd(A, C))
    D = _madd(t, t)                       # 2*((X+B)^2 - A - C)
    E = _madd(A, _madd(A, A))             # 3*A
    F = _mmul(E, E)
    X3 = _msub(F, _madd(D, D))
    eight_c = _madd(_madd(_madd(_madd(_madd(_madd(_madd(C, C), C), C), C), C), C), C)
    Y3 = _msub(_mmul(E, _msub(D, X3)), eight_c)
    Z3 = _mmul(_madd(Y1, Y1), Z1)         # 2*Y*Z
    return (X3, Y3, Z3)


def _jadd(X1, Y1, Z1, X2, Y2, Z2):
    if Z1 == 0:
        return (X2, Y2, Z2)
    if Z2 == 0:
        return (X1, Y1, Z1)
    Z1Z1 = _mmul(Z1, Z1)
    Z2Z2 = _mmul(Z2, Z2)
    U1 = _mmul(X1, Z2Z2)
    U2 = _mmul(X2, Z1Z1)
    S1 = _mmul(Y1, _mmul(Z2, Z2Z2))
    S2 = _mmul(Y2, _mmul(Z1, Z1Z1))
    if U1 == U2:
        if S1 == S2:
            return _jdouble(X1, Y1, Z1)
        return (0, 0, 0)
    H = _msub(U2, U1)
    I = _mmul(_madd(H, H), _madd(H, H))   # (2H)^2
    J = _mmul(H, I)
    r = _madd(_msub(S2, S1), _msub(S2, S1))  # 2*(S2-S1)
    V = _mmul(U1, I)
    X3 = _msub(_msub(_mmul(r, r), J), _madd(V, V))
    Y3 = _msub(_mmul(r, _msub(V, X3)), _mmul(_madd(S1, S1), J))
    Z3 = _mmul(_msub(_msub(_mmul(_madd(Z1, Z2), _madd(Z1, Z2)), Z1Z1), Z2Z2), H)
    return (X3, Y3, Z3)


def scalarmul(k, X=GX, Y=GY):
    """k * (X, Y); returns affine (x, y)."""
    if k == 0 or k >= N:
        raise ValueError("scalar out of range")
    JX, JY, JZ = 0, 0, 0
    started = False
    for i in range(k.bit_length() - 1, -1, -1):
        if started:
            JX, JY, JZ = _jdouble(JX, JY, JZ)
        if (k >> i) & 1:
            JX, JY, JZ = _jadd(JX, JY, JZ, X, Y, 1)
            started = True
    zi = _inv(JZ, P)
    z2 = _mmul(zi, zi)
    z3 = _mmul(z2, zi)
    return (_mmul(JX, z2), _mmul(JY, z3))


def pubkey_bytes(d: int) -> bytes:
    x, y = scalarmul(d)
    return x.to_bytes(32, "big") + y.to_bytes(32, "big")


# ---------------------------------------------------------------------------
# RFC 6979 (HMAC-SHA256 DRBG) + ECDSA sign (low-S, 65-byte output)
# ---------------------------------------------------------------------------

def rfc6979_k(priv: bytes, z: int) -> int:
    x = priv
    h1 = z.to_bytes(32, "big")
    v = b"\x01" * 32
    k = b"\x00" * 32
    k = hmac.new(k, v + b"\x00" + x + h1, hashlib.sha256).digest()
    v = hmac.new(k, v, hashlib.sha256).digest()
    k = hmac.new(k, v + b"\x01" + x + h1, hashlib.sha256).digest()
    v = hmac.new(k, v, hashlib.sha256).digest()
    while True:
        v = hmac.new(k, v, hashlib.sha256).digest()
        candidate = int.from_bytes(v, "big")
        if 1 <= candidate < N:
            return candidate
        k = hmac.new(k, v + b"\x00", hashlib.sha256).digest()
        v = hmac.new(k, v, hashlib.sha256).digest()


def sign(priv: bytes, z: int):
    """Returns (r, s, recid) with low-s normalization."""
    d = int.from_bytes(priv, "big")
    z = z % N
    k = rfc6979_k(priv, z)
    rx, ry = scalarmul(k)
    r = rx % N
    if r == 0:
        raise ValueError("r == 0 (retry)")
    s = (_inv(k, N) * (z + r * d)) % N
    if s == 0:
        raise ValueError("s == 0 (retry)")
    recid = (1 if ry & 1 else 0) | (2 if rx >= N else 0)
    if s > N // 2:
        s = N - s
        recid ^= 1
    return r, s, recid


def verify_pure(pub: bytes, z: int, r: int, s: int) -> bool:
    """Standard ECDSA verify; pub is the 64-byte uncompressed key."""
    if not (0 < r < N and 0 < s < N):
        return False
    x, y = int.from_bytes(pub[:32], "big"), int.from_bytes(pub[32:], "big")
    if (y * y - (x * x * x + 7)) % P != 0:
        return False
    w = _inv(s, N)
    u1 = (z * w) % N
    u2 = (r * w) % N
    g1 = scalarmul(u1) if u1 else None
    g2 = scalarmul(u2, x, y) if u2 else None
    if g1 is None:
        return g2 is not None and g2[0] % N == r
    if g2 is None:
        return g1[0] % N == r
    JX, JY, JZ = _jadd(g1[0], g1[1], 1, g2[0], g2[1], 1)
    zi = _inv(JZ, P)
    z2 = _mmul(zi, zi)
    rx = _mmul(JX, z2)
    return rx % N == r


# ---------------------------------------------------------------------------
# Base58Check (TRON style: 0x41 prefix, double-SHA256 checksum)
# ---------------------------------------------------------------------------

_B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def base58encode(b: bytes) -> str:
    n = int.from_bytes(b, "big")
    out = ""
    while n:
        n, rem = divmod(n, 58)
        out = _B58[rem] + out
    for byte in b:
        if byte == 0:
            out = "1" + out
        else:
            break
    return out


def base58decode(s: str) -> bytes:
    n = 0
    for ch in s:
        n = n * 58 + _B58.index(ch)
    raw = n.to_bytes((n.bit_length() + 7) // 8, "big") if n else b""
    for ch in s:
        if ch == "1":
            raw = b"\x00" + raw
        else:
            break
    return raw


def pubkey_to_address(pub: bytes) -> str:
    digest = keccak256(pub)
    payload = b"\x41" + digest[12:]
    checksum = hashlib.sha256(hashlib.sha256(payload).digest()).digest()[:4]
    return base58encode(payload + checksum)


def address_hex(addr: str) -> bytes:
    raw = base58decode(addr)
    checksum = hashlib.sha256(hashlib.sha256(raw[:-4]).digest()).digest()[:4]
    assert raw[-4:] == checksum, "bad checksum"
    assert raw[0] == 0x41 and len(raw) == 25
    return raw[:-4]


# ---------------------------------------------------------------------------
# Protobuf writer/reader (the exact logic TronSigner.swift implements)
# ---------------------------------------------------------------------------

def pv_varint(v: int) -> bytes:
    out = bytearray()
    while v >= 0x80:
        out.append((v & 0x7F) | 0x80)
        v >>= 7
    out.append(v)
    return bytes(out)


def pv_bytes(field: int, data: bytes) -> bytes:
    return pv_varint((field << 3) | 2) + pv_varint(len(data)) + data


def pv_int(field: int, v: int) -> bytes:
    return pv_varint((field << 3) | 0) + pv_varint(v & ((1 << 64) - 1))


def read_fields(data: bytes):
    """Yield (field_number, wire_type, value_bytes)."""
    pos = 0
    while pos < len(data):
        tag, pos = _read_varint(data, pos)
        field, wire = tag >> 3, tag & 7
        if wire == 0:
            value, pos = _read_varint(data, pos)
        elif wire == 2:
            length, pos = _read_varint(data, pos)
            value = data[pos:pos + length]
            pos += length
        else:
            raise ValueError("unexpected wire type %d" % wire)
        yield field, wire, value


def _read_varint(data, pos):
    value = 0
    shift = 0
    while True:
        byte = data[pos]
        pos += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, pos
        shift += 7


def build_contract(kind: int, inner: bytes, type_url: str) -> bytes:
    any_msg = pv_bytes(1, type_url.encode()) + pv_bytes(2, inner)
    return pv_int(1, kind) + pv_bytes(2, any_msg)


def build_transfer_contract(owner21: bytes, to21: bytes, amount: int) -> bytes:
    return pv_bytes(1, owner21) + pv_bytes(2, to21) + pv_int(3, amount)


def build_trigger_contract(owner21: bytes, contract21: bytes, data: bytes, call_value: int = 0) -> bytes:
    out = pv_bytes(1, owner21) + pv_bytes(2, contract21)
    if call_value:
        out += pv_int(3, call_value)
    return out + pv_bytes(4, data)


def build_raw(ref_block_bytes: bytes, ref_block_hash: bytes, expiration: int,
              timestamp: int, contract: bytes, fee_limit) -> bytes:
    out = pv_bytes(1, ref_block_bytes)
    out += pv_bytes(4, ref_block_hash)
    out += pv_int(8, expiration)
    out += pv_bytes(11, contract)
    out += pv_int(14, timestamp)
    if fee_limit:
        out += pv_int(18, fee_limit)
    return out


def sign_raw(priv: bytes, raw: bytes) -> bytes:
    z = int.from_bytes(hashlib.sha256(raw).digest(), "big")
    r, s, recid = sign(priv, z)
    sig = r.to_bytes(32, "big") + s.to_bytes(32, "big") + bytes([recid])
    return pv_bytes(2, sig)


def build_signed_tx(priv: bytes, raw: bytes):
    txid = hashlib.sha256(raw).hexdigest()
    signed = pv_bytes(1, raw) + sign_raw(priv, raw)
    return txid, signed.hex()


def block_ref(block_id_hex: str):
    return (bytes.fromhex(block_id_hex[12:16]),
            bytes.fromhex(block_id_hex[16:32]))


# ---------------------------------------------------------------------------
# CHECKS
# ---------------------------------------------------------------------------

failures = []


def check(name, ok, detail=""):
    status = "PASS" if ok else "FAIL"
    print(f"[{status}] {name}" + (f"  {detail}" if detail and not ok else ""))
    if not ok:
        failures.append(name)


def main():
    print("== Keccak-256 ==")
    check("keccak('')", keccak256(b"").hex() == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
    check("keccak('abc')", keccak256(b"abc").hex() == "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")

    print("== secp256k1 ==")
    x2, y2 = scalarmul(2)
    check("2*G", x2 == 0xC6047F9441ED7D6D3045406E95C07CD85C778E4B8CEF3CA7ABAC09B95C709EE5
          and y2 == 0x1AE168FEA63DC339A3C58419466CEAEEF7F632653266D0E1236431A950CFE52A)
    x3, y3 = scalarmul(3)
    JX, JY, JZ = _jadd(x2, y2, 1, GX, GY, 1)
    zi = _inv(JZ, P)
    z2 = _mmul(zi, zi)
    check("3*G == 2*G + G", (_mmul(JX, z2), _mmul(JY, z2 * zi % P)) == (x3, y3))

    print("== ECDSA cross-checks ==")
    import coincurve
    priv = bytes.fromhex("01".rjust(64, "0"))
    msg = hashlib.sha256(b"LapTimer-TRON-self-test").digest()
    z = int.from_bytes(msg, "big")
    pub = pubkey_bytes(1)
    cc_pub = coincurve.PublicKey.from_secret(priv).format(compressed=False)[1:]
    check("pubkey matches coincurve", cc_pub == pub)
    r, s, recid = sign(priv, z)
    check("verify own signature (pure)", verify_pure(pub, z, r, s))
    sig65 = r.to_bytes(32, "big") + s.to_bytes(32, "big") + bytes([recid])
    cc_recover_pub = coincurve.PublicKey.from_signature_and_message(sig65, msg, hasher=None)
    check("coincurve recovers our pubkey from our sig", cc_recover_pub.format(compressed=False)[1:] == pub)
    rb = r.to_bytes(32, "big").lstrip(b"\x00")
    sb = s.to_bytes(32, "big").lstrip(b"\x00")
    if rb[0] & 0x80: rb = b"\x00" + rb
    if sb[0] & 0x80: sb = b"\x00" + sb
    der_body = b"\x02" + bytes([len(rb)]) + rb + b"\x02" + bytes([len(sb)]) + sb
    der_sig = b"\x30" + bytes([len(der_body)]) + der_body
    check("coincurve (libsecp256k1) verifies our RFC6979 signature",
          coincurve.verify_signature(der_sig, msg, b"\x04" + cc_pub, hasher=None))
    cc_sig = coincurve.PrivateKey(priv).sign_recoverable(msg, hasher=None)
    cc_r = int.from_bytes(cc_sig[:32], "big")
    cc_s = int.from_bytes(cc_sig[32:64], "big")
    check("our verify accepts coincurve signature", verify_pure(pub, z, cc_r, cc_s))
    check("tampered signature rejected", not verify_pure(pub, z, r, (s + 1) % N))

    print("== Live chain: verify real USDT (TriggerSmartContract) tx ==")
    ev = _get("/v1/contracts/" + USDT + "/events?event_name=Transfer&limit=3&order_by=block_timestamp,desc")
    usdt_txid = ev["data"][0]["transaction_id"]
    tx = _post("/wallet/gettransactionbyid", {"value": usdt_txid})
    raw_hex = tx["raw_data_hex"]
    raw = bytes.fromhex(raw_hex)
    check("txid == sha256(raw)", hashlib.sha256(raw).hexdigest() == usdt_txid)
    sig65 = bytes.fromhex(tx["signature"][0])
    check("signature is 65 bytes", len(sig65) == 65)
    r_ch, s_ch, recid_ch = (int.from_bytes(sig65[:32], "big"), int.from_bytes(sig65[32:64], "big"), sig65[64])
    check("recid byte in 0..3", 0 <= recid_ch <= 3, f"recid={recid_ch}")
    z_ch = int.from_bytes(hashlib.sha256(raw).digest(), "big")
    if 0 <= recid_ch <= 3:
        recover_pub = coincurve.PublicKey.from_signature_and_message(sig65, hashlib.sha256(raw).digest(), hasher=None)
        pub64 = recover_pub.format(compressed=False)[1:]
        owner_hex = tx["raw_data"]["contract"][0]["parameter"]["value"]["owner_address"]
        check("recovered address == owner_address", address_hex(pubkey_to_address(pub64)).hex() == owner_hex,
              f"got {pubkey_to_address(pub64)} want {owner_hex}")
        check("pure verify passes on real chain signature", verify_pure(pub64, z_ch, r_ch, s_ch))
    else:
        print("[skip] unusual recid byte; recovery checks skipped for this tx")
    # byte-level protobuf comparison of the raw
    contract = tx["raw_data"]["contract"][0]
    param = contract["parameter"]["value"]
    owner21 = bytes.fromhex(param["owner_address"])
    contract21 = bytes.fromhex(param["contract_address"])
    data = bytes.fromhex(param["data"])
    call_value = param.get("call_value", 0)
    inner = build_trigger_contract(owner21, contract21, data, call_value)
    contract_bytes = build_contract(31, inner, "type.googleapis.com/protocol.TriggerSmartContract")
    rr = tx["raw_data"]
    rebuilt = build_raw(bytes.fromhex(rr["ref_block_bytes"]), bytes.fromhex(rr["ref_block_hash"]),
                        rr["expiration"], rr.get("timestamp", 0), contract_bytes, rr.get("fee_limit", 0))
    check("USDT raw bytes rebuild byte-identical", rebuilt == raw,
          f"rebuilt {len(rebuilt)}B vs chain {len(raw)}B")
    if rebuilt != raw:
        a = list(read_fields(raw))
        b = list(read_fields(rebuilt))
        check("field sequence matches", a == b, f"chain={[(f, w, (v[:12].hex() if isinstance(v, bytes) else v)) for f, w, v in a]}")

    print("== Live chain: verify real TRX (TransferContract) tx ==")
    trx_tx = None
    fingerprint = ""
    for page in range(8):
        url = f"/v1/accounts/{owner21.hex()}/transactions?limit=50&order_by=block_timestamp,desc&only_confirmed=true"
        if fingerprint:
            url += "&fingerprint=" + fingerprint
        page_json = _get(url)
        rows = page_json["data"]
        for row in rows:
            ct = row["raw_data"]["contract"][0]
            if ct["type"] == "TransferContract":
                trx_tx = row
                break
        if trx_tx:
            break
        fingerprint = page_json.get("meta", {}).get("fingerprint", "")
        if not rows or not fingerprint:
            break
    check("found a TransferContract tx on chain", trx_tx is not None)
    if trx_tx:
        raw2 = bytes.fromhex(trx_tx["raw_data_hex"])
        check("trx txid == sha256(raw)", hashlib.sha256(raw2).hexdigest() == trx_tx["txID"])
        sig2 = bytes.fromhex(trx_tx["signature"][0])
        if len(sig2) == 65 and 0 <= sig2[64] <= 3:
            recover2 = coincurve.PublicKey.from_signature_and_message(sig2, hashlib.sha256(raw2).digest(), hasher=None)
            pub2 = recover2.format(compressed=False)[1:]
            owner2 = trx_tx["raw_data"]["contract"][0]["parameter"]["value"]["owner_address"]
            check("TRX recovered address == owner_address", address_hex(pubkey_to_address(pub2)).hex() == owner2)
        else:
            print("[skip] unusual TRX signature; recovery checks skipped")
        rr = trx_tx["raw_data"]
        ct = trx_tx["raw_data"]["contract"][0]
        param = ct["parameter"]["value"]
        inner2 = build_transfer_contract(bytes.fromhex(param["owner_address"]), bytes.fromhex(param["to_address"]), param["amount"])
        contract2 = build_contract(1, inner2, "type.googleapis.com/protocol.TransferContract")
        rebuilt2 = build_raw(bytes.fromhex(rr["ref_block_bytes"]), bytes.fromhex(rr["ref_block_hash"]),
                             rr["expiration"], rr.get("timestamp", 0), contract2, rr.get("fee_limit", 0))
        check("TRX raw bytes rebuild byte-identical", rebuilt2 == raw2, f"rebuilt {len(rebuilt2)}B vs chain {len(raw2)}B")

    print("== Address derivation ==")
    check("privkey 0x01 -> G pubkey", pubkey_bytes(1).hex() ==
          "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
          "483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8")
    print("  address(0x01) =", pubkey_to_address(pubkey_bytes(1)))

    print("== Build signed transactions (Swift self-test vectors) ==")
    block = _get("/wallet/getnowblock")
    block_id_hex = block["blockID"]
    block_ts = block["block_header"]["raw_data"]["timestamp"]
    ref_b, ref_h = block_ref(block_id_hex)
    expiration = block_ts + 60_000
    timestamp = block_ts + 1_000
    fixed_priv = bytes.fromhex("9c8b1f6d3e7a2b5c4d8e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e")
    my_addr = pubkey_to_address(pubkey_bytes(int.from_bytes(fixed_priv, "big")))
    usdt21 = address_hex(USDT)
    dest = pubkey_to_address(pubkey_bytes(123456789))
    dest21 = address_hex(dest)
    print("  self address =", my_addr)
    print("  dest address =", dest)

    # TRX: 1.5 TRX = 1_500_000 SUN
    trx_contract = build_contract(1, build_transfer_contract(address_hex(my_addr), dest21, 1_500_000), "type.googleapis.com/protocol.TransferContract")
    trx_raw = build_raw(ref_b, ref_h, expiration, timestamp, trx_contract, 10_000_000)
    trx_txid, trx_signed = build_signed_tx(fixed_priv, trx_raw)

    # USDT: 12.34 * 1e6 base units
    usdt_contract = build_contract(31, build_trigger_contract(
        address_hex(my_addr), usdt21,
        bytes.fromhex("a9059cbb") + b"\x00" * 12 + dest21[1:] + (12_340_000).to_bytes(32, "big")),
        "type.googleapis.com/protocol.TriggerSmartContract")
    usdt_raw = build_raw(ref_b, ref_h, expiration, timestamp, usdt_contract, 50_000_000)
    usdt_txid, usdt_signed = build_signed_tx(fixed_priv, usdt_raw)

    print()
    print("=== SWIFT SELF-TEST VECTORS ===")
    print(f'keccakEmpty = "{keccak256(b"").hex()}"')
    print(f'keccakAbc = "{keccak256(b"abc").hex()}"')
    print(f"address01 = \"{pubkey_to_address(pubkey_bytes(1))}\"")
    print(f"address123456789 = \"{dest}\"")
    print(f"privFixed = \"{fixed_priv.hex()}\"")
    print(f"selfAddress = \"{my_addr}\"")
    print(f"refBlockID = \"{block_id_hex}\"")
    print(f"refBlockBytes = \"{ref_b.hex()}\"")
    print(f"refBlockHash = \"{ref_h.hex()}\"")
    print(f"expiration = {expiration}")
    print(f"timestamp = {timestamp}")
    print(f"trxTxid = \"{trx_txid}\"")
    print(f"trxSignedHex = \"{trx_signed}\"")
    print(f"usdtTxid = \"{usdt_txid}\"")
    print(f"usdtSignedHex = \"{usdt_signed}\"")
    print(f'rfc6979Msg = "{msg.hex()}"')
    print(f'rfc6979K = "{rfc6979_k(priv, z % N):064x}"')
    print(f'rfc6979R = "{r:064x}"')
    print(f'rfc6979S = "{s:064x}"')
    print(f'rfc6979Recid = {recid}')

    print()
    if failures:
        print(f"{len(failures)} FAILURES: {failures}")
        return 1
    print("ALL CHECKS PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
