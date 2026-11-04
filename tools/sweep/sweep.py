#!/usr/bin/env python3
# sweep.py — auto-sweep BTC from a SOLVED puzzle private key to a safe address.
#
# Triggered by run_keyhunt_jump.sh / run_collider_jump.sh when a MATCH is found.
# Flow:
#   1. derive the puzzle P2PKH address from the config PUBKEY (compressed),
#   2. sanity-check it equals config TARGET_HASH160,
#   3. fetch UTXOs (blockstream/esplora),
#   4. build + sign a P2PKH tx sending the FULL balance (minus fee) to SWEEP_ADDRESS,
#   5. broadcast it.
#
# PENDING QUEUE (sejak 2026-11-04):
#   Kalau MATCH terjadi saat TIDAK ADA KONEKSI, job TIDAK hilang dan TIDAK
#   dianggap gagal: job ditulis ke tools/sweep/pending/<puzzle>_<hash>.json
#   (0600, gitignored) dan process keluar dengan rc=75. Retry otomatis:
#     - tiap siklus sync daemon (runners/sync.sh -> sync_push),
#     - saat start-all,
#     - manual: python3 tools/sweep/sweep.py --retry-pending --confirm
#   Saat koneksi kembali, job dikirim ulang sampai BROADCAST OK.
#
# Safety:
#   - private key lives only in memory, never logged. Pending job menyimpan priv
#     HANYA di file lokal 0600 (tidak pernah di-commit, lihat .gitignore).
#   - SWEEP_ADDRESS defaults to the project's BTC puzzle-solve sweep address
#     (tools/sweep/SWEEP_ADDRESS, else built-in). Override with env SWEEP_ADDRESS.
#   - SWEEP_DRYRUN=1 (or --dry-run): fetch + build + sign but DO NOT broadcast.
#   - --confirm wajib untuk broadcast sungguhan (tanpa itu selalu dry-run).
#   - Invalid MATCH (priv tidak cocok TARGET_HASH160/PUBKEY) TIDAK pernah
#     masuk pending — itu kegagalan permanen (anti-zonk).
#
# Deps: coincurve, python-bitcoinlib, requests
import sys, os, glob, time, argparse, hashlib, struct, json
from coincurve import PrivateKey
import requests

ESP = os.environ.get("ESP_API", "https://blockstream.info/api")
NET_PREFIX = 0x00  # mainnet; 0x6f for testnet
SAT_PER_VB = int(os.environ.get("SWEEP_SATVB", "0")) or None  # None => auto from fee-estimates
DUST = 546
SWEEP_DEFAULT = "1PqYBqJAsT6AVCAr6ueuTYuRUu61NHet5"  # BTC puzzle-solve sweep addr (AGENTS.md)

_HERE = os.path.dirname(os.path.abspath(__file__))
PENDING_DIR = os.path.join(_HERE, "pending")
DONE_LOG = os.path.join(_HERE, "sweep_done.log")
PENDING_RC = 75  # EX_TEMPFAIL: "coba lagi nanti", BUKAN gagal permanen


class TransientNetError(Exception):
    """Koneksi/endpoint tidak tersedia — job masuk antrean pending."""


class SweepError(Exception):
    """Kegagalan permanen (MATCH invalid, dust, tx ditolak) — jangan diulang."""


def resolve_sweep_address():
    # env SWEEP_ADDRESS > tools/sweep/SWEEP_ADDRESS > built-in default
    if os.environ.get("SWEEP_ADDRESS"):
        return os.environ["SWEEP_ADDRESS"].strip()
    f = os.path.join(_HERE, "SWEEP_ADDRESS")
    try:
        if os.path.exists(f):
            for ln in open(f):
                ln = ln.strip()
                if ln and not ln.startswith("#"):
                    return ln
    except OSError:
        pass
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
    try:
        r = requests.get(f"{ESP}/address/{addr}/utxos", timeout=30)
    except requests.exceptions.RequestException as e:
        # Koneksi putus / timeout / DNS / proxy / redirect: SEMUA transient —
        # job wajib masuk pending, jangan sampai kunci hilang.
        raise TransientNetError(f"cannot reach UTXO API: {e}")
    if r.status_code == 404:
        return []  # address with no transaction history
    if r.status_code >= 400:
        # 429 rate-limit, 5xx, dll: transien. Retry nanti.
        raise TransientNetError(f"UTXO API HTTP {r.status_code}: {r.text[:160]}")
    try:
        return r.json()
    except ValueError as e:
        raise TransientNetError(f"UTXO API response bukan JSON valid: {e}")


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
        raise SweepError("pubkey does not match private key")
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
        raise SweepError(f"sweep addr not a P2PKH for this network (prefix 0x{NET_PREFIX:02x})")
    out_script = b"\x76\xa9\x14" + h[1:] + b"\x88\xac"
    fee = fee_satvb * (len(ins) * 148 + 1 * 34 + 10)
    send = total_in - fee
    if send < DUST:
        raise SweepError(f"dust after fee (in={total_in} fee={fee} send={send})")
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
            raise SweepError(f"self-verify FAILED on input {i}")
    return out, total_in, fee, send


# ---- pending queue ---------------------------------------------------------
def _pending_path(cfg_path: str, priv_hex: str) -> str:
    try:
        puzzle = parse_config(cfg_path).get("PUZZLE", "?")
    except Exception:
        puzzle = "?"
    tag = hashlib.sha256(priv_hex.lower().encode()).hexdigest()[:16]
    # Suffix .job.json = job AKTIF. File .failed.json / .bad.json adalah arsip
    # audit dan TIDAK boleh ikut di-retry (dulu bug: glob *.json ikut memungut
    # arsip -> retry berulang, akhiran menumpuk .failed.failed.json).
    return os.path.join(PENDING_DIR, f"p{puzzle}_{tag}.job.json")


def _write_json_0600(path: str, obj: dict):
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f, indent=2)
    os.replace(tmp, path)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def enqueue_pending(cfg_path: str, priv_hex: str, sweep_addr: str, reason: str) -> str:
    os.makedirs(PENDING_DIR, exist_ok=True)
    try:
        os.chmod(PENDING_DIR, 0o700)
    except OSError:
        pass
    path = _pending_path(cfg_path, priv_hex)
    now = time.strftime("%Y-%m-%dT%H:%M:%S")
    job = {
        "config": os.path.abspath(cfg_path),
        "priv": priv_hex,
        "sweep": sweep_addr,
        "created": now,
        "attempts": 0,
        "last_error": reason,
    }
    if os.path.exists(path):
        try:
            old = json.load(open(path))
            job["created"] = old.get("created", now)
            job["attempts"] = int(old.get("attempts", 0))
        except Exception:
            pass
    job["attempts"] += 1
    job["last_try"] = now
    _write_json_0600(path, job)
    return path


def dequeue_pending(cfg_path: str, priv_hex: str):
    try:
        os.remove(_pending_path(cfg_path, priv_hex))
    except FileNotFoundError:
        pass


def _log_done(puzzle: str, sweep_addr: str):
    try:
        with open(DONE_LOG, "a") as f:
            f.write(f"PUZZLE={puzzle} ADDR={sweep_addr}\n")
    except OSError:
        pass


# ---- one sweep attempt -----------------------------------------------------
def sweep_once(cfg_path: str, priv_hex: str, sweep_addr: str, dry: bool = False):
    """Return ("sent"|"no-utxos"|"dry", detail).
    Raise TransientNetError (pending) atau SweepError (permanen)."""
    try:
        cfg = parse_config(cfg_path)
        priv_int = int(priv_hex, 16)
    except (OSError, ValueError) as e:
        raise SweepError(f"config/priv tidak valid: {e}")
    pub_hex = cfg.get("PUBKEY", "")
    tgt = cfg.get("TARGET_HASH160", "")
    puzzle = cfg.get("PUZZLE", "?")
    try:
        pk = PrivateKey.from_int(priv_int)
        derived_pub = pk.public_key.format(compressed=True)
        if not pub_hex:
            pub_hex = derived_pub.hex()
            addr = h160_to_addr(hash160(derived_pub))
        else:
            addr = addr_from_pub(pub_hex)
    except ValueError as e:
        raise SweepError(f"config/priv tidak valid: {e}")
    print(f"[sweep] puzzle address = {addr}")

    # GUARANTEE THE MATCH IS VALID before moving any funds:
    # the found private key MUST derive exactly the puzzle's TARGET_HASH160.
    if bytes.fromhex(pub_hex) not in (derived_pub, pk.public_key.format(compressed=False)):
        raise SweepError("private key does NOT derive the config PUBKEY -> invalid MATCH, abort sweep")
    if tgt:
        if hash160(derived_pub).hex() != tgt.lower():
            raise SweepError(f"private key derives hash160 != TARGET_HASH160 ({tgt}) -> invalid MATCH, abort sweep")
        print("[sweep] MATCH VALID: priv -> PUBKEY -> TARGET_HASH160 verified OK")
    else:
        # Anti-zonk: selalu WAJIB ada anchor verifikasi.
        print("[sweep] MATCH VALID: priv -> config PUBKEY verified OK (tanpa TARGET_HASH160 di config)")

    print(f"[sweep] sweep destination = {sweep_addr}")
    utxos = get_utxos(addr)
    if not utxos:
        print("[sweep] NO UTXOs on this address -> nothing to sweep (still a valid solve).")
        return ("no-utxos", None)
    total = sum(u["value"] for u in utxos)
    print(f"[sweep] {len(utxos)} UTXO(s), total = {total/1e8:.8f} BTC")
    fee_satvb = get_fee_satvb()
    raw, total_in, fee, send = build_and_sign(pub_hex, priv_int, utxos, sweep_addr, fee_satvb)
    print(f"[sweep] fee ~ {fee} sat ({fee_satvb} sat/vB); sending {send/1e8:.8f} BTC")
    rawhex = raw.hex()
    if dry:
        print(f"[sweep DRY-RUN] raw tx ({len(raw)} bytes):\n{rawhex}")
        print("[sweep DRY-RUN] NOT broadcast.")
        return ("dry", rawhex)

    try:
        r = requests.post(f"{ESP}/tx", data=rawhex, timeout=30,
                          headers={"Content-Type": "text/plain"})
    except requests.exceptions.RequestException as e:
        raise TransientNetError(f"broadcast failed (offline): {e}")
    if r.status_code >= 500 or r.status_code == 429:
        # server sibuk / rate limit: transien, aman diulang nanti.
        raise TransientNetError(f"broadcast API HTTP {r.status_code}: {r.text[:160]}")
    if r.status_code >= 400:
        # 4xx = tx ditolak (bukan masalah koneksi). Jangan diulang selamanya.
        raise SweepError(f"broadcast rejected HTTP {r.status_code}: {r.text[:240]}")
    txid = r.text.strip()
    print(f"[sweep] BROADCAST OK txid = {txid}")
    print(f"[sweep] explorer: https://blockstream.info/tx/{txid}")
    _log_done(puzzle, sweep_addr)
    return ("sent", txid)


def retry_pending(dry: bool = False) -> int:
    """Proses semua job pending. return 0 = tidak ada sisa, 75 = masih pending."""
    if not os.path.isdir(PENDING_DIR):
        return 0
    # HANYA job aktif (.job.json). Arsip .failed.json/.bad.json tidak pernah
    # di-retry — kalau ikut, kegagalan permanen akan berulang tiap siklus.
    jobs = sorted(glob.glob(os.path.join(PENDING_DIR, "*.job.json")))
    if not jobs:
        return 0
    remaining = 0

    def archive(path, kind):
        base = path[:-len(".job.json")] if path.endswith(".job.json") else os.path.splitext(path)[0]
        dst = base + kind
        if os.path.exists(dst):
            # jangan timpa arsip audit lama (match/puzzle yang sama gagal lagi)
            dst = base + "." + time.strftime("%Y%m%dT%H%M%S") + kind
        os.replace(path, dst)

    for path in jobs:
        try:
            job = json.load(open(path))
        except Exception as e:
            print(f"[pending] {os.path.basename(path)}: file rusak ({e}) -> .bad.json")
            archive(path, ".bad.json")
            continue
        cfg = job.get("config", "")
        priv = job.get("priv", "")
        sweep_addr = job.get("sweep", "") or resolve_sweep_address()
        if not cfg or not priv:
            print(f"[pending] {os.path.basename(path)}: data tidak lengkap -> .bad.json")
            archive(path, ".bad.json")
            continue
        print(f"\n[pending] retry {os.path.basename(path)} (attempt {int(job.get('attempts', 0)) + 1})")
        try:
            status, _ = sweep_once(cfg, priv, sweep_addr, dry)
        except TransientNetError as e:
            job["attempts"] = int(job.get("attempts", 0)) + 1
            job["last_error"] = str(e)
            job["last_try"] = time.strftime("%Y-%m-%dT%H:%M:%S")
            _write_json_0600(path, job)
            print(f"[pending] MASIH OFFLINE: {e} — job disimpan, dicoba lagi nanti.")
            remaining += 1
            continue
        except SweepError as e:
            job["failed_reason"] = str(e)
            job["last_try"] = time.strftime("%Y-%m-%dT%H:%M:%S")
            _write_json_0600(path, job)
            archive(path, ".failed.json")
            print(f"[pending] GAGAL PERMANEN: {e} — job dipindah ke .failed.json untuk audit manual.")
            continue
        except Exception as e:  # jangan biarkan 1 job rusak menghentikan antrean
            job["failed_reason"] = f"{type(e).__name__}: {e}"
            job["last_try"] = time.strftime("%Y-%m-%dT%H:%M:%S")
            _write_json_0600(path, job)
            archive(path, ".failed.json")
            print(f"[pending] GAGAL PERMANEN (unexpected): {e} — job dipindah ke .failed.json.")
            continue
        if status == "dry":
            print("[pending] DRY-RUN: job TIDAK dihapus (belum benar-benar dikirim).")
            remaining += 1
        else:
            os.remove(path)
            print(f"[pending] selesai ({status}) — job dihapus dari antrean.")
    return PENDING_RC if remaining else 0


def main():
    global ESP, NET_PREFIX
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", help="config puzzle (wajib kecuali --retry-pending)")
    ap.add_argument("--priv", help="solved private key hex (256-bit)")
    ap.add_argument("--sweep", default=resolve_sweep_address())
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--confirm", action="store_true",
                    help="required to actually broadcast; without this flag, sweep is always dry-run")
    ap.add_argument("--retry-pending", action="store_true",
                    help="proses antrean tools/sweep/pending/ (dipakai sync daemon & start-all)")
    ap.add_argument("--testnet", action="store_true", help="use blockstream testnet API + testnet addresses")
    args = ap.parse_args()

    if args.testnet:
        ESP = "https://blockstream.info/testnet/api"
        NET_PREFIX = 0x6F
    dry = args.dry_run or os.environ.get("SWEEP_DRYRUN") == "1" or not args.confirm

    if args.retry_pending:
        return retry_pending(dry)

    if not args.config or not args.priv:
        ap.error("--config dan --priv wajib (kecuali memakai --retry-pending)")
    try:
        status, _ = sweep_once(args.config, args.priv, args.sweep, dry)
    except TransientNetError as e:
        p = enqueue_pending(args.config, args.priv, args.sweep, str(e))
        print(f"[sweep PENDING] {e}")
        print(f"[sweep PENDING] job disimpan: {p}")
        print("[sweep PENDING] akan dikirim otomatis begitu koneksi kembali "
              "(sync daemon / start-all / --retry-pending).")
        return PENDING_RC
    except SweepError as e:
        raise SystemExit(f"ERROR: {e}")
    if status in ("sent", "no-utxos"):
        dequeue_pending(args.config, args.priv)
    return 0


if __name__ == "__main__":
    sys.exit(main())
