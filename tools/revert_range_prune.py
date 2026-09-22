#!/usr/bin/env python3
"""revert_range_prune.py — buang entri checkpoint/pct_history era EXPAND range (collider).

KONTEKS (keputusan user 2026-09-22):
  * 2026-09-21 06:41 commit `72de49d` me-EXPAND config collider_jump_* dari
    subrange lama ke range resmi penuh [2^(n-1), 2^n). Keputusan baru:
    KEMBALIKAN config ke state PRA-EXPAND (subrange lama) dan buang SEMUA
    entri progress yang tercatat saat range baru aktif, supaya pct di
    checkpoint / pct_history tetap bermakna terhadap config sekarang.

KEISTIMEWAAN collider: entri ckpt menyimpan {presentage, hex} dan runner MEMAKAI
hex itu (set guard dobel: `seen` dari ckpt + hasil konversi pct_history via
hex_at(config)). Setelah config di-revert, hex entri yg dipertahankan ikut
DIHITUNG ULANG dari pct memakai range lama:
    hex = "0x%x" % (S + (R * e8) // 10000000000)     (identik dgn hex_at runner,
    formula sudah diverifikasi 7705/7705 entri thd penyimpanan era expanded)
supaya guard hidup lagi & data konsisten.

Dua lapis penanda di record `revert_range_20260922.keys` (immutable, ikut
ter-push) — karena key union driver = hex (ikut berubah saat recompute), sedangkan
aturan script harus stabil terhadap recompute:
    PCTDROP<TAB><path><TAB><pct>  aturan SCRIPT: buang entri ckpt yg pct-nya ini
                                  ATAU baris history ini (key = pct = identitas
                                  entri yg tidak pernah berubah).
    GLOBAL<TAB><key>              utk UNION DRIVER saja: hex LAMA entri yang
                                  dibuang + hex lama (superseded) entri yang
                                  dipertahankan + n:<pct> history yang dibuang.
                                  Tanpa ini, salinan mesin lain (hex versi
                                  expanded) dianggap entri baru -> dobel/nyangkut.
    SCOPED<TAB><path><TAB><key>   bentrok key lintas file -> hanya script.
  <key> = key_of() milik union driver (di-IMPORT, bukan disalin tangan).

GUARD: bila config puzzle sudah di range resmi PENUH (S == 2^(n-1) dan
E == 2^n - 1) script NO-OP total — artinya EXPAND ulang disengaja dan entri lama
kembali valid. (Kalau EXPAND ulang: hapus juga record + hook runners/sync.sh +
denylist merge driver.)

Pakai:
    python3 tools/revert_range_prune.py --init    # SEKALI: hitung, tulis record, hapus + recompute hex
    python3 tools/revert_range_prune.py           # idempoten: PCTDROP + recompute (aman kapan pun)
    python3 tools/revert_range_prune.py --check   # laporan tanpa menulis apapun

Jalankan SETELAH config ke-revert (`git checkout 72de49d~1 -- configs/`) —
recompute hex MEMBACA config.
"""
import glob
import os
import re
import subprocess
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOLS)
import merge_progress_union as drv  # noqa: E402  (key_of HARUS sama persis)

REPO = os.path.dirname(TOOLS)  # root repo collider/
REF = "72de49d~1"  # state PRA-EXPAND (commit sebelum EXPAND 2026-09-21)
RECORD = os.path.join(REPO, "revert_range_20260922.keys")
PATTERNS = [
    "checkpoints/randomColliders*.js",
    "logs/*.pct_history",
]
PCT_IN_CKPT = re.compile(r'(?:start|presentage):\s*"([^"]+)"')
NUM_RE = re.compile(r"(\d+)")


def git_show(path):
    r = subprocess.run(
        ["git", "-C", REPO, "show", "%s:%s" % (REF, path)],
        capture_output=True, text=True,
    )
    return r.stdout if r.returncode == 0 else None


def is_entry(rel, line):
    s = line.strip()
    if not s:
        return False
    if rel.startswith("checkpoints/"):
        return s.startswith("{")
    return not s.startswith("let") and s != "]"  # pct_history = angka polos


def read_lines(abs_path):
    with open(abs_path) as f:
        return f.read().splitlines()


def write_atomic(abs_path, lines):
    tmp = abs_path + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(lines) + ("\n" if lines else ""))
    os.replace(tmp, abs_path)


def current_files():
    out = []
    for pat in PATTERNS:
        out.extend(sorted(glob.glob(os.path.join(REPO, pat))))
    return out


def rel_of(abs_path):
    return os.path.relpath(abs_path, REPO)


def puzzle_of(rel):
    m = NUM_RE.search(os.path.basename(rel))
    return int(m.group(1)) if m else None


def ckpt_range(rel):
    """(S, R, conf) utk file ckpt/history berdasarkan config yg SEDANG berlaku.

    Untuk history file dipetakan juga ke config puzzle yg sama (pN_cj_rnd.* -> N)."""
    n = puzzle_of(rel)
    if n is None:
        return None
    conf = os.path.join(REPO, "configs", "collider_jump_p%d_rnd.conf" % n)
    if not os.path.exists(conf):
        return None
    S = E = None
    with open(conf) as f:
        for ln in f:
            if ln.strip().startswith("START="):
                S = int(ln.split("=", 1)[1].strip(), 16)
            elif ln.strip().startswith("END="):
                E = int(ln.split("=", 1)[1].strip(), 16)
    if S is None or E is None:
        return None
    return S, E - S, conf


def skipped(rel):
    """True bila config puzzle = range resmi penuh -> script no-op utk file ini."""
    rng = ckpt_range(rel)
    if rng is None:
        return False
    n = puzzle_of(rel)
    S, _, _ = rng
    E = S  # recompute E dari conf agar bandingkan dgn 2^n - 1
    conf = rng[2]
    with open(conf) as f:
        for ln in f:
            if ln.strip().startswith("END="):
                E = int(ln.split("=", 1)[1].strip(), 16)
    return S == (1 << (n - 1)) and E == (1 << n) - 1


def to_e8(s):
    if "." in s:
        i, fr = s.split(".", 1)
    else:
        i, fr = s, ""
    fr = (fr + "00000000")[:8]
    return int(i) * 100000000 + int(fr)


def hex_at_conf(s_pct, rng):
    """hex utk pct memakai config yang berlaku — identik dgn hex_at runner."""
    S, R, _ = rng
    x = "%x" % (S + (R * to_e8(s_pct)) // 10000000000)
    return "0x" + (x.lstrip("0") or "0")


def pct_of_ckpt(ln):
    m = PCT_IN_CKPT.search(ln)
    return m.group(1) if m else None


def pra_pcts(rel):
    """Set pct entri di file versi REF. None = file tidak ada di REF."""
    old = git_show(rel)
    if old is None:
        return None
    out = set()
    for ln in old.splitlines():
        if not is_entry(rel, ln):
            continue
        if rel.startswith("checkpoints/"):
            p = pct_of_ckpt(ln)
            if p:
                out.add(p)
        else:
            out.add(ln.strip())
    return out


def load_record():
    """-> (global_keys, scoped: {rel: {key}}, pctdrop: {rel: {pct}})"""
    g, sc, pd = set(), {}, {}
    if not os.path.exists(RECORD):
        return g, sc, pd
    with open(RECORD) as f:
        for ln in f:
            ln = ln.rstrip("\n")
            if ln.startswith("GLOBAL\t"):
                g.add(ln.split("\t", 1)[1])
            elif ln.startswith("PCTDROP\t"):
                parts = ln.split("\t")
                if len(parts) == 3:
                    pd.setdefault(parts[1], set()).add(parts[2])
            elif ln.startswith("SCOPED\t"):
                parts = ln.split("\t")
                if len(parts) == 3:
                    sc.setdefault(parts[1], set()).add(parts[2])
    return g, sc, pd


def recompute_ckpt(p, check_only=False):
    """Hitung ulang hex entri ckpt pakai config yang berlaku. -> jumlah berubah."""
    rel = rel_of(p)
    if not rel.startswith("checkpoints/") or skipped(rel):
        return 0
    rng = ckpt_range(rel)
    if rng is None:
        print("WARN: config tidak ditemukan utk", rel)
        return 0
    lines = read_lines(p)
    changed, out = 0, []
    for ln in lines:
        if is_entry(rel, ln):
            pct = pct_of_ckpt(ln)
            if pct:
                want = hex_at_conf(pct, rng)
                cur = drv.key_of(ln)[2:]  # "c:0x.." -> "0x.."
                if cur != want:
                    changed += 1
                    ln = re.sub(r'hex:\s*"[^"]+"', 'hex: "%s"' % want, ln)
        out.append(ln)
    if changed and not check_only:
        write_atomic(p, out)
    return changed


def entry_dropped(rel, ln, pd):
    """Aturan drop script = PCTDROP (stabil terhadap recompute hex)."""
    if rel.startswith("checkpoints/"):
        pct = pct_of_ckpt(ln)
        return pct is not None and pct in pd.get(rel, set())
    return ln.strip() in pd.get(rel, set())


def do_check():
    g, sc, pd = load_record()
    if not (g or sc or pd):
        print("[check] record belum ada — jalankan --init dulu.")
    tot = 0
    for p in current_files():
        rel = rel_of(p)
        if skipped(rel):
            print("  %-40s SKIP (config range resmi penuh)" % rel)
            continue
        if pd or g:
            n = sum(1 for ln in read_lines(p)
                    if is_entry(rel, ln) and entry_dropped(rel, ln, pd))
        else:  # pra-init: hitung kandidat vs REF
            pp = pra_pcts(rel)
            n = 0
            if pp is not None:
                for ln in read_lines(p):
                    if not is_entry(rel, ln):
                        continue
                    v = pct_of_ckpt(ln) if rel.startswith("checkpoints/") else ln.strip()
                    if v not in pp:
                        n += 1
        rc = recompute_ckpt(p, check_only=True)
        if n or rc:
            print("  %-40s %d entri kena, %d hex perlu recompute" % (rel, n, rc))
            tot += n
    print("[check] total kandidat: %d" % tot)
    return 0


def do_apply(check_only=False):
    g, sc, pd = load_record()
    if not (g or sc or pd):
        print("record tidak ada (%s) — tidak ada yg dikerjakan. "
              "Jalankan --init sekali di mesin revert." % os.path.basename(RECORD))
        return 1
    tot = 0
    for p in current_files():
        rel = rel_of(p)
        if skipped(rel):
            continue  # EXPAND ulang? -> no-op utk puzzle ini
        lines = read_lines(p)
        keep, dropped = [], 0
        for ln in lines:
            if is_entry(rel, ln) and entry_dropped(rel, ln, pd):
                dropped += 1
                continue
            keep.append(ln)
        if dropped:
            print("  %-40s buang %d entri" % (rel, dropped))
            tot += dropped
            if not check_only:
                write_atomic(p, keep)
        if not check_only:
            rc = recompute_ckpt(p, check_only=False)
            if rc:
                print("  %-40s hex direcompute utk %d entri" % (rel, rc))
    print("[%s] total %d entri dibuang"
          % ("check" if check_only else "apply", tot))
    return 0


def do_init(force=False):
    if os.path.exists(RECORD) and not force:
        print("record sudah ada (%s) — --init hanya sekali (pakai --force "
              "kalau yakin mau ulang)." % os.path.basename(RECORD))
        return 1

    pending = {}    # GLOBAL/SCOPED key -> set(rel): hex lama (dibuang + superseded)
    pctdrop = {}    # rel -> set(pct) aturan drop script
    kept = {}       # rel -> set(key entri dipertahankan, key SAAT INI)
    warnings = []

    for p in current_files():
        rel = rel_of(p)
        if skipped(rel):
            warnings.append("config sudah range penuh — DILEWATI: %s" % rel)
            continue
        pp = pra_pcts(rel)
        if pp is None:
            warnings.append("file tidak ada di %s — DILEWATI (tidak dihapus): %s"
                            % (REF, rel))
            continue
        rng = ckpt_range(rel) if rel.startswith("checkpoints/") else None
        keep_keys = set()
        for ln in read_lines(p):
            if not is_entry(rel, ln):
                continue
            k = drv.key_of(ln)
            if rel.startswith("checkpoints/"):
                pct = pct_of_ckpt(ln)
                in_pra = pct is not None and pct in pp
            else:
                in_pra = ln.strip() in pp
            if in_pra:
                keep_keys.add(k)
                # hex lama entri dipertahankan = superseded oleh recompute
                # -> tetap harus denylist utk salinan mesin lain
                if rng is not None:
                    pct = pct_of_ckpt(ln)
                    if pct and k[2:] != hex_at_conf(pct, rng):
                        pending.setdefault(k, set()).add(rel)
            else:
                pending.setdefault(k, set()).add(rel)
                pctdrop.setdefault(rel, set()).add(
                    pct_of_ckpt(ln) if rel.startswith("checkpoints/") else ln.strip())
        kept[rel] = keep_keys

    # collision: key pending yang jadi entri KELOLA di file LAIN -> SCOPED
    # (file sendiri dikecualikan — overlap superseded dgn kept di file sama itu wajar)
    global_keys, scoped_keys = set(), {}
    for k, files in sorted(pending.items()):
        owners = [r for r, ks in kept.items() if r not in files and k in ks]
        if owners:
            for rel in files:
                scoped_keys.setdefault(rel, set()).add(k)
        else:
            global_keys.add(k)

    with open(RECORD, "w") as f:
        f.write("# revert_range_20260922.keys — denylist entri era EXPAND range\n")
        f.write("# (config collider_jump_* di-revert ke subrange pra-EXPAND\n")
        f.write("# 2026-09-22 per keputusan user; entri ini tercatat saat range\n")
        f.write("# penuh aktif 21-22 Sep 2026 sehingga pct-nya salah tafsir utk\n")
        f.write("# config lama. Termasuk hex LAMA entri dipertahankan (superseded\n")
        f.write("# oleh recompute hex dgn range lama — kalau tidak, union driver\n")
        f.write("# menganggap salinan mesin lain entri baru -> dobel).\n")
        f.write("# PCTDROP = aturan drop utk script (berbasis pct, stabil terhadap\n")
        f.write("# recompute). GLOBAL = utk union driver (berbasis key baris).\n")
        f.write("# Dipakai: (1) tools/merge_progress_union.py utk menyaring baris\n")
        f.write("# kedua sisi merge antar mesin, (2) tools/revert_range_prune.py\n")
        f.write("# (idempoten, aman kapan pun).\n")
        f.write("# Kalau kelak EXPAND diulang secara sengaja: hapus file ini,\n")
        f.write("# hook di runners/sync.sh, dan denylist di merge driver.\n")
        f.write("# format: PCTDROP\\t<path>\\t<pct> | GLOBAL\\t<key> | SCOPED\\t<path>\\t<key>\n")
        for rel in sorted(pctdrop):
            for pct in sorted(pctdrop[rel]):
                f.write("PCTDROP\t%s\t%s\n" % (rel, pct))
        for k in sorted(global_keys):
            f.write("GLOBAL\t%s\n" % k)
        for rel in sorted(scoped_keys):
            for k in sorted(scoped_keys[rel]):
                f.write("SCOPED\t%s\t%s\n" % (rel, k))

    n_pd = sum(len(v) for v in pctdrop.values())
    n_ss = sum(len(v) for v in pending.values())
    print("record ditulis: %d PCTDROP, %d key pending (%d GLOBAL, %d SCOPED)"
          % (n_pd, n_ss, len(global_keys),
             sum(len(v) for v in scoped_keys.values())))
    for w in warnings:
        print("WARN:", w)
    return do_apply(check_only=False)


def main():
    args = set(sys.argv[1:])
    if "--init" in args:
        return do_init(force="--force" in args)
    if "--check" in args:
        return do_check()
    return do_apply(check_only=False)


if __name__ == "__main__":
    sys.exit(main())
