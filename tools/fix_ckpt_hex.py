#!/usr/bin/env python3
"""fix_ckpt_hex.py — bersihkan hex salah faktor-100 di checkpoint randomColliders*.

LATAR (AGENTS.md §13): hex_at() lama di run_collider_jump.sh kena bug ÷100 —
    hex_lama = S + (R * e8) // 1e8      # SALAH (faktor 100 terlalu besar)
seharusnya (cocok dgn kernel GPU: startOff = 2^(n-1) * pct/100, START=2^(n-1)):
    hex_benar = S + (R * e8) // 1e10

PCT yang tercatat di ckpt & pct_history BENAR (dibaca ulang GPU-independent),
jadi hex cukup DIREGENERASI dari pct yang sama. Efek:
  - Entri duplikat by pct (hex lama vs baru berbeda string) menyatu jadi satu.
  - pick_random_start() tidak akan re-pick subrange yang pernah discan (dedup
    by hex regenerasi = konsisten dgn yang GPU benar-benar kunjungi).

PENTING: GPU selalu scan full range resmi (binary abaikan START/END config),
jadi satu entri pct hanya mewakili TITIK start (window 0.1% di sekitarnya) —
ini keterbatasan bookkeeping lama yang memang sudah demikian; cleaner hanya
membuat hex-nya jujur terhadap titik tersebut.

Pakai:
  python3 tools/fix_ckpt_hex.py --check          # lihat apa yg akan berubah
  python3 tools/fix_ckpt_hex.py                  # apply (atomic, backup .bak)
  python3 tools/fix_ckpt_hex.py --file PATH      # satu file saja
"""
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                           # collider/  (tools/ induknya)
CONF_DIR = os.path.join(ROOT, "configs")
CKPT_DIR = os.path.join(ROOT, "checkpoints")
LOG_DIR = os.path.join(ROOT, "logs")

ENT_RE = re.compile(r'presentage:\s*"([^"]+)"\s*,\s*hex:\s*"([^"]+)"')


def conf_field(path, key):
    for ln in open(path, encoding="utf-8", errors="replace"):
        s = ln.strip()
        if s.startswith(key + "="):
            return s.split("=", 1)[1].strip()
    return ""


def load_conf(puzzle):
    """START/END config = range resmi [2^(n-1), 2^n)."""
    cands = sorted(glob.glob(os.path.join(CONF_DIR, "collider_jump_p%s*_rnd.conf" % puzzle)))
    if not cands:
        return None
    c = cands[0]
    try:
        S = int(conf_field(c, "START"), 16)
        E = int(conf_field(c, "END"), 16)
    except (ValueError, TypeError):
        return None
    if E <= S:
        return None
    return c, S, E


def to_e8(s):
    if "." in s:
        i, f = s.split(".", 1)
    else:
        i, f = s, ""
    f = (f + "00000000")[:8]
    try:
        return int(i) * 100000000 + int(f)
    except ValueError:
        return None


def hex_benar(S, R, e8):
    # Rumus diperbaiki (kernel GPU: off = half * pct/100; S = half → S + pct*R/100)
    x = "%x" % (S + (R * e8) // 10000000000)
    return "0x" + (x.lstrip("0") or "0")


def hex_lama(S, R, e8):
    # Rumus bug lama — untuk statistik berapa entri yang memang berubah
    x = "%x" % (S + (R * e8) // 100000000)
    return "0x" + (x.lstrip("0") or "0")


def fix_file(path, S, R, apply):
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines(True)
    out, seen_pct, report = [], {}, {"n": 0, "changed": 0, "dropped_dup": 0, "bad": 0}
    for ln in lines:
        m = ENT_RE.search(ln)
        if not m:
            out.append(ln)
            continue
        e8 = to_e8(m.group(1))
        if e8 is None:
            out.append(ln)
            report["bad"] += 1
            continue
        if e8 in seen_pct:            # duplikat by pct (hex beda string saja)
            report["dropped_dup"] += 1
            continue
        seen_pct[e8] = True
        newhex = hex_benar(S, R, e8)
        old_in_file = m.group(2)
        report["n"] += 1
        if old_in_file != newhex:
            report["changed"] += 1
        out.append(re.sub(
            r'(presentage:\s*"[^"]+"\s*,\s*hex:\s*)"[^"]+"',
            lambda mm: '%s"%s"' % (mm.group(1), newhex), ln))
    if apply and (report["changed"] or report["dropped_dup"]):
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.writelines(out)
        os.replace(tmp, path)
    return report


def main():
    apply = "--check" not in sys.argv
    onefile = None
    if "--file" in sys.argv:
        onefile = sys.argv[sys.argv.index("--file") + 1]

    files = [(onefile, os.path.basename(onefile))] if onefile else [
        (p, os.path.basename(p)) for p in sorted(
            glob.glob(os.path.join(CKPT_DIR, "randomColliders*.js")))]

    if not files:
        print("TIDAK ADA checkpoint yg cocok.")
        return 1

    total = {"n": 0, "changed": 0, "dropped_dup": 0, "bad": 0}
    print("%-28s %6s %8s %8s %5s" % ("file", "entri", "ubah", "dupHapus", "bad"))
    for path, name in files:
        m = re.search(r"randomColliders(\d+)\.js$", name)
        if not m:
            print("%-28s (skip: nama tak dikenal)" % name)
            continue
        conf = load_conf(m.group(1))
        if not conf:
            print("%-28s (skip: config START/END tidak valid)" % name)
            continue
        _, S, E = conf
        R = E - S
        rep = fix_file(path, S, R, apply)
        for k in total:
            total[k] += rep[k]
        print("%-28s %6d %8d %8d %5d" % (name, rep["n"], rep["changed"], rep["dropped_dup"], rep["bad"]))
    print("-" * 60)
    print("TOTAL entri=%d  berubah=%d  dup-dropped=%d  bad=%d  [%s]"
          % (total["n"], total["changed"], total["dropped_dup"], total["bad"],
             "APPLIED" if apply else "CHECK ONLY"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
