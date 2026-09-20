#!/usr/bin/env python3
"""merge_progress_union.py — git merge driver utk file progress collider (append-only).

Dipanggil git via .gitattributes:
  checkpoints/randomColliders*.js merge=progressUnion
  logs/*.pct_history             merge=progressUnion

Union + dedup: ckpt collider punya {presentage, hex: 0x...} -> key dari hex;
format keyhunt {start:...} -> key dari start; pct_history angka polos -> key
dari baris. Entry baru dari 'theirs' disisipkan sebelum ']' (ckpt) atau
ditambahkan di belakang (history).

KONTRAK GIT MERGE DRIVER: hasil DITULIS ke file %A (argv[2]) in-place, exit 0.
Dipasang otomatis oleh runners/run_all_colliders.sh (merge.progressUnion.driver).
"""
import re
import sys

HEX_RE = re.compile(r'hex:\s*"(0x[0-9a-fA-F]+)"')
PCT_RE = re.compile(r'(?:start|presentage):\s*"([^"]+)"')
# Self-healing: marker konflik yang pernah ter-commit di file progress dibuang
# sebelum union, supaya riwayat yang tercemar otomatis bersih saat merge berikutnya.
MARKER_RE = re.compile(r'^(<{7}|={7}|>{7})')


def clean_lines(text: str):
    return [ln for ln in text.splitlines() if not MARKER_RE.match(ln)]


def key_of(line: str) -> str:
    m = HEX_RE.search(line)
    if m:
        return "c:" + m.group(1).lower()
    m = PCT_RE.search(line)
    if m:
        return "p:" + m.group(1)
    parts = line.split()
    if len(parts) == 1:
        return "n:" + parts[0]          # pct_history angka polos
    if len(parts) >= 2:
        return "h:" + parts[1]          # "pct hex" gaya keyhunt
    return "l:" + line


def merge_lines(base_text: str, ours_text: str, theirs_text: str) -> str:
    base_keys = {key_of(ln) for ln in clean_lines(base_text)}
    ours_lines = clean_lines(ours_text)
    seen = {key_of(ln) for ln in ours_lines}

    new_lines = []
    for ln in clean_lines(theirs_text):
        k = key_of(ln)
        if k in seen or k in base_keys:
            continue
        new_lines.append(ln)
        seen.add(k)

    out = list(ours_lines)
    if new_lines and out and out[-1].strip() == "]":
        out[-1:-1] = new_lines          # sisip sebelum ']' -> ckpt tetap valid JS
    else:
        out.extend(new_lines)

    if new_lines:
        sys.stderr.write("progressUnion: +%d baris dari remote\n" % len(new_lines))
    return "\n".join(out) + "\n"


def main() -> int:
    if len(sys.argv) != 4:
        sys.stderr.write("usage: %s <base> <ours> <theirs>\n" % sys.argv[0])
        return 0
    try:
        with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as f:
            base_text = f.read()
        with open(sys.argv[2], "r", encoding="utf-8", errors="replace") as f:
            ours_text = f.read()
        with open(sys.argv[3], "r", encoding="utf-8", errors="replace") as f:
            theirs_text = f.read()
    except OSError:
        return 0

    merged = merge_lines(base_text, ours_text, theirs_text)
    try:
        with open(sys.argv[2], "w", encoding="utf-8") as f:
            f.write(merged)
    except OSError:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
