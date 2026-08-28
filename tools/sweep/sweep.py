#!/usr/bin/env python3
# sweep.py — auto-sweep BTC from a SOLVED puzzle private key to a safe address.
#
# Triggered by run_collider_jump.sh when metal-kangaroo prints "SOLVED k = ...".
# Flow:
#   1. derive the puzzle P2PKH address from the config PUBKEY (compressed),
#   2. sanity-check it equals config TARGET_HASH160,
#   3. fetch UTXOs (blockstream/esplora),
#   4. build + sign a P2PKH tx sending the FULL balance (minus fee) to SWEEP_ADDRESS,
#   5. broadcast it.
#
# Safety:
#   - private key lives only in memory, never logged.
#   - SWEEP_ADDRESS defaults to the project's BTC puzzle-solve sweep address
#     (see AGENTS.md). Override with env SWEEP_ADDRESS or --sweep.
#   - SWEEP_DRYRUN=1 (or --dry-run): fetch + build + sign but DO NOT broadcast
#     (prints the signed raw tx + would-be txid). Use this to validate first.
#
# Deps: coincurve, python-bitcoinlib, requests  (all already present on this Mac)
import sys, os, argparse, hashlib, struct, json
from coincurve import PrivateKey
import requests

ESP = os.environ.get("ESP_API", "https://blockstream.info/api")
NET_PREFIX = 0x00  # mainnet; 0x6f for testnet
SAT_PER_VB = int(os.environ.get("SWEEP_SATVB", "0")) or None  # None => auto from fee-estimates
DUST = 546
SWEEP_DEFAULT = "1PqYBqJAsT6AVCAr6ueuTYuRUu61NHet5"  # BTC puzzle-solve sweep addr (AGENTS.md)


def resolve_sweep_address():
    # env SWEEP_ADDRESS > tools/sweep/SWEEP_ADDRESS > built-in default
    if os.environ.get("SWEEP_ADDRESS"):
        return os.environ["SWEEP_ADDRESS"].strip()
    f = os.path.join(os.path.dirname(os.path.abspath(__file__)), "SWEEP_ADDRESS")
    if os.path.exists(f):
        for ln in open(f):
            ln = ln.strip()
            if ln and not ln.startswith("#"):
                return ln
    return SWEEP_DEFAULT

_B58 = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def b58encode(b: bytes) -> str:
    n = int.from_bytes(b, "big")
    out = b""
    while n:
        n, r = divmod(n, 58)
        out = bytes([_B58[r]]) + out
    pad = 0
    for c in b:
        if c == 0:
            pad += 1
        else:
            break
    return "1" * pad + out.decode()


def b58encode_check(b: bytes) -> str:
    return b58encode(b + hashlib.sha256(hashlib.sha256(b).digest()).digest()[:4])


def b58decode_check(s: str) -> bytes:
    pad = 0
    for c in s:
        if c == "1":
            pad += 1
        else:
            break
    n = 0
    for c in s:
        n = n * 58 + _B58.index(ord(c))
    b = n.to_bytes((n.bit_length() + 7) // 8 + pad, "big")
    return b[:-4]


def hash160(b: bytes) -> bytes:
    return hashlib.new("ripemd160", hashlib.sha256(b).digest()).digest()


def dblsha(b):
    return hashlib.sha256(hashlib.sha256(b).digest()).digest()


def h160_to_addr(h160: bytes) -> str:
    return b58encode_check(bytes([NET_PREFIX]) + h160)


def addr_from_pub(pub_hex: str) -> str:
    return h160_to_addr(hash160(bytes.fromhex(pub_hex)))


def parse_config(conf: str):
    f = {}
    for ln in open(conf):
        ln = ln.strip()
        if "=" in ln and not ln.startswith("#"):
            k, v = ln.split("=", 1)
            f[k.strip()] = v.strip()
    return f


def get_utxos(addr: str):
    r = requests.get(f"{ESP}/address/{addr}/utxos", timeout=30)
    if r.status_code == 404:
        return []  # address with no transaction history
    r.raise_for_status()
    return r.json()


def get_fee_satvb() -> int:
    if SAT_PER_VB:
        return SAT_PER_VB
    try:
        r = requests.get(f"{ESP}/fee-estimates", timeout=30).json()
        # pick a conservative-ish 2-block target if present
        vb = r.get("2") or min(r.values())
        return max(1, int(round(float(vb))))
    except Exception:
        return 5


def build_and_sign(pub_hex, priv_int, utxos, sweep_addr, fee_satvb):
    pub = bytes.fromhex(pub_hex)
    priv = PrivateKey.from_int(priv_int)
    if priv.public_key.format(compressed=True) != pub and priv.public_key.format(compressed=False) != pub:
        raise SystemExit("ERROR: pubkey does not match private key")
    script_pubkey = b"\x76\xa9\x14" + hash160(pub) + b"\x88\xac"  # P2PKH scriptPubKey
    ins = []
    total_in = 0
    for u in utxos:
        txid = bytes.fromhex(u["txid"])[::-1]
        vout = u["vout"]
        amt = u["value"]
        total_in += amt
        ins.append((txid, vout, amt))
    h = b58decode_check(sweep_addr)
    if h[0] != NET_PREFIX:
        raise SystemExit(f"ERROR: sweep addr not a P2PKH for this network (prefix 0x{NET_PREFIX:02x})")
    out_script = b"\x76\xa9\x14" + h[1:] + b"\x88\xac"
    fee = fee_satvb * (len(ins) * 148 + 1 * 34 + 10)
    send = total_in - fee
    if send < DUST:
        raise SystemExit(f"ERROR: dust after fee (in={total_in} fee={fee} send={send})")
    version = struct.pack("<I", 1)
    locktime = struct.pack("<I", 0)
    out_val = struct.pack("<Q", send) + bytes([len(out_script)]) + out_script
    signed_scripts = []
    for i, (txid, vout, amt) in enumerate(ins):
        pre = version + struct.pack("<B", len(ins))
        for j, (t, v, a) in enumerate(ins):
            pre += t + struct.pack("<I", v)
            if j == i:
                pre += bytes([len(script_pubkey)]) + script_pubkey + struct.pack("<I", 0xFFFFFFFF)
            else:
                pre += b"\x00" + struct.pack("<I", 0xFFFFFFFF)
        pre += b"\x01" + out_val + locktime
        pre += struct.pack("<I", 1)  # SIGHASH_ALL
        sighash = dblsha(pre)
        sig = priv.sign(sighash) + b"\x01"  # DER + SIGHASH_ALL
        signed_scripts.append(bytes([len(sig)]) + sig + bytes([len(pub)]) + pub)
    # serialize final legacy tx (legacy: counts are 1-byte varints)
    out = version + struct.pack("<B", len(ins))
    for i, (txid, vout, amt) in enumerate(ins):
        out += txid + struct.pack("<I", vout) + bytes([len(signed_scripts[i])]) + signed_scripts[i] + struct.pack("<I", 0xFFFFFFFF)
    out += b"\x01" + out_val + locktime
    # self-verify every signature before returning (catches sighash bugs)
    for i, (t, v, a) in enumerate(ins):
        pre2 = version + struct.pack("<B", len(ins))
        for j, (t2, v2, a2) in enumerate(ins):
            pre2 += t2 + struct.pack("<I", v2)
            if j == i:
                pre2 += bytes([len(script_pubkey)]) + script_pubkey + struct.pack("<I", 0xFFFFFFFF)
            else:
                pre2 += b"\x00" + struct.pack("<I", 0xFFFFFFFF)
        pre2 += b"\x01" + out_val + locktime + struct.pack("<I", 1)
        sh = dblsha(pre2)
        sl = signed_scripts[i]
        sig = sl[1:1 + sl[0] - 1]
        if not priv.public_key.verify(sig, sh):
            raise SystemExit(f"ERROR: self-verify FAILED on input {i}")
    return out, total_in, fee, send


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--priv", required=True, help="solved private key hex (256-bit)")
    ap.add_argument("--sweep", default=resolve_sweep_address())
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--confirm", action="store_true",
                    help="required to actually broadcast; without this flag, sweep is always dry-run")
    ap.add_argument("--testnet", action="store_true", help="use blockstream testnet API + testnet addresses")
    args = ap.parse_args()

    if args.testnet:
        ESP = "https://blockstream.info/testnet/api"
        NET_PREFIX = 0x6F
    dry = args.dry_run or os.environ.get("SWEEP_DRYRUN") == "1" or not args.confirm
    cfg = parse_config(args.config)
    pub_hex = cfg.get("PUBKEY", "")
    tgt = cfg.get("TARGET_HASH160", "")

    priv_int = int(args.priv, 16)
    pk = PrivateKey.from_int(priv_int)
    derived_pub = pk.public_key.format(compressed=True)

    # Keyhunt-style configs carry only TARGET_HASH160 (no PUBKEY): derive the
    # pubkey from the private key and verify it against the target hash160.
    if not pub_hex:
        pub_hex = derived_pub.hex()
        addr = h160_to_addr(hash160(derived_pub))
    else:
        addr = addr_from_pub(pub_hex)
    print(f"[sweep] puzzle address = {addr}")

    # GUARANTEE THE MATCH IS VALID before moving any funds:
    # the found private key MUST derive exactly the puzzle's TARGET_HASH160.
    if bytes.fromhex(pub_hex) not in (derived_pub, pk.public_key.format(compressed=False)):
        raise SystemExit("ERROR: private key does NOT derive the config PUBKEY -> invalid MATCH, abort sweep")
    if tgt:
        if hash160(derived_pub).hex() != tgt.lower():
            raise SystemExit(f"ERROR: private key derives hash160 != TARGET_HASH160 ({tgt}) -> invalid MATCH, abort sweep")
        print("[sweep] MATCH VALID: priv -> PUBKEY -> TARGET_HASH160 verified OK")

    print(f"[sweep] sweep destination = {args.sweep}")
    try:
        utxos = get_utxos(addr)
    except Exception as e:
        raise SystemExit(f"ERROR: cannot fetch UTXOs: {e}")
    if not utxos:
        print("[sweep] NO UTXOs on this address -> nothing to sweep (still a valid solve).")
        return
    total = sum(u["value"] for u in utxos)
    print(f"[sweep] {len(utxos)} UTXO(s), total = {total/1e8:.8f} BTC")
    fee_satvb = get_fee_satvb()
    raw, total_in, fee, send = build_and_sign(pub_hex, priv_int, utxos, args.sweep, fee_satvb)
    print(f"[sweep] fee ~ {fee} sat ({fee_satvb} sat/vB); sending {send/1e8:.8f} BTC")
    rawhex = raw.hex()
    if dry:
        print(f"[sweep DRY-RUN] raw tx ({len(raw)} bytes):\n{rawhex}")
        print("[sweep DRY-RUN] NOT broadcast.")
        return
    try:
        r = requests.post(f"{ESP}/tx", data=rawhex, timeout=30,
                          headers={"Content-Type": "text/plain"})
        r.raise_for_status()
        txid = r.text.strip()
        print(f"[sweep] BROADCAST OK txid = {txid}")
        print(f"[sweep] explorer: https://blockstream.info/tx/{txid}")
        with open(os.path.join(os.path.dirname(__file__), "sweep_done.log"), "a") as f:
            f.write(f"{addr} -> {args.sweep} txid={txid}\n")
    except Exception as e:
        raise SystemExit(f"ERROR: broadcast failed: {e}\nraw tx was:\n{rawhex}")


if __name__ == "__main__":
    main()
