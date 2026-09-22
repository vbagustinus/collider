#!/usr/bin/env bash
# trim_logs.sh — rotasi/trim log runtime di collider/logs biar nggak numpuk.
#
# Padanan tools/trim_logs.sh di repo keyhunt (kebijakan sama). Collider
# sebelumnya TIDAK punya pemangkas sama sekali → metal.log tumbuh tanpa batas
# (~1,9 MB/hari utk 5 config = 57 MB/bulan) sementara AGENTS.md repo ini
# menyatakan "Log runtime di-trim otomatis" (aturan 5) — script ini
# mewujudkan kesepakatan itu.
#
# Kebijakan (urut eksekusi):
#   1. Log runtime lebih tua dari TRIM_DAYS hari         -> HAPUS
#   2. Log runtime lebih besar dari TRIM_MAX_FILE_MB     -> POTONG, simpan
#      tail TRIM_TAIL_MB terakhir (bukti jalan terbaru tetap ada)
#   3. Total logs/ melebihi TRIM_TOTAL_MB                -> hapus log runtime
#      paling tua dulu sampai di bawah cap
#
# YANG TIDAK PERNAH DISENTUH (data penting / terlacak git):
#   - logs/*.pct_history   (progress kangaroo — di-merge driver union)
#   - logs/*MATCH*, logs/FOUND_*   (bukti temuan semua mesin)
#   - logs/.col_found_seen (penanda runtime alert match)
#   - logs/.pids/          (pid file master/runner)
#   - checkpoints/*        (di direktori lain, script ini tidak menyentuhnya)
#   - File yang sedang dibuka proses (dicek via lsof) -> skip
#
# Pakai:
#   bash tools/trim_logs.sh            # dipanggil start-all/stop-all
#   bash tools/trim_logs.sh --dry-run  # cuma tampil, nggak hapus/potong
#   TRIM_DAYS=2 bash tools/trim_logs.sh
#
# Default: TRIM_DAYS=3  TRIM_MAX_FILE_MB=100  TRIM_TAIL_MB=10  TRIM_TOTAL_MB=300

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT/logs"
SWEPT_DIR="$ROOT/tools/sweep"          # log sweep telemetri (juga di-ignore)
DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

: "${TRIM_DAYS:=3}"
: "${TRIM_MAX_FILE_MB:=100}"
: "${TRIM_TAIL_MB:=10}"
: "${TRIM_TOTAL_MB:=300}"

mkdir -p "$LOG_DIR"

# Pola log runtime yang BOLEH di-trim (KEEP_RE di bawah menang)
CANDIDATES=(
  *_rnd.metal.log
  *.metal.log
  sweep_scheduler.log
  sweep_*.log
  *.sweep.log
  sweep_done.log
  daemon_launch.log
)
KEEP_RE='(pct_history|MATCH|FOUND|\.col_found_seen$|^\.kh_found_seen$)'

is_busy() { lsof -- "$1" >/dev/null 2>&1; }

act() {
  if [[ $DRY -eq 1 ]]; then echo "[dry] $1"; else echo "[trim] $1"; fi
}

# --- kumpulkan kandidat (logs/ + tools/sweep/), dedup biar nggak dobel hitung ---
files=()
has_file() { local x; for x in "${files[@]-}"; do [[ "$x" == "$1" ]] && return 0; done; return 1; }
collect_from() {
  local dir="$1"; shift
  local pat f
  [[ -d "$dir" ]] || return 0
  for pat in "$@"; do
    for f in "$dir"/$pat; do
      [[ -f "$f" ]] || continue
      [[ "$(basename "$f")" =~ $KEEP_RE ]] && continue
      has_file "$f" && continue
      files+=("$f")
    done
  done
}
collect_from "$LOG_DIR" "${CANDIDATES[@]}"
collect_from "$SWEPT_DIR" "sweep_done.log" "*.sweep.log" "sweep_*.log"

if [[ ${#files[@]} -eq 0 ]]; then
  echo "[trim] nggak ada kandidat log runtime."
  exit 0
fi

freed=0; deleted=0; truncated=0

# --- 1) hapus yang tua ---
now=$(date +%s)
alive=()
for f in "${files[@]}"; do
  m=$(stat -f %m "$f" 2>/dev/null) || { alive+=("$f"); continue; }
  age=$(( (now - m) / 86400 ))
  if (( age >= TRIM_DAYS )); then
    if is_busy "$f"; then
      act "SKIP (dipakai proses): $f"
      alive+=("$f")
      continue
    fi
    szk=$(du -k "$f" 2>/dev/null | cut -f1); szk=${szk:-0}
    freed=$((freed + szk)); deleted=$((deleted + 1))
    act "hapus (usia ${age}d, ${szk}KB): $f"
    [[ $DRY -eq 0 ]] && rm -f "$f"
  else
    alive+=("$f")
  fi
done

# --- 2) potong yang gede ---
for f in "${alive[@]}"; do
  [[ -f "$f" ]] || continue
  szk=$(du -k "$f" 2>/dev/null | cut -f1); szk=${szk:-0}
  maxk=$((TRIM_MAX_FILE_MB * 1024))
  if (( szk > maxk )); then
    if is_busy "$f"; then
      act "SKIP (dipakai proses): $f"
      continue
    fi
    tail_bytes=$((TRIM_TAIL_MB * 1024 * 1024))   # tail -c hitung BYTE
    freed=$((freed + szk - TRIM_TAIL_MB * 1024)); truncated=$((truncated + 1))
    act "potong (${szk}KB -> tail ${TRIM_TAIL_MB}MB): $f"
    if [[ $DRY -eq 0 ]]; then
      tail -c "$tail_bytes" "$f" > "$f.trimtmp" && mv "$f.trimtmp" "$f"
    fi
  fi
done

# --- 3) cap total direktori (logs/ saja; checkpoint di luar) ---
capk=$((TRIM_TOTAL_MB * 1024))
totalk=$(du -sk "$LOG_DIR" 2>/dev/null | cut -f1); totalk=${totalk:-0}
if (( totalk > capk )); then
  act "total logs/ ${totalk}KB > cap ${capk}KB — hapus runtime-log tertua dulu"
fi
while (( totalk > capk )); do
  victim=""; oldest=0
  for f in "${alive[@]}"; do
    [[ -f "$f" ]] || continue
    m=$(stat -f %m "$f" 2>/dev/null) || continue
    if (( oldest == 0 || m < oldest )); then oldest=$m; victim="$f"; fi
  done
  [[ -z "$victim" ]] && { act "nggak ada kandidat lagi; stop di total ${totalk}KB"; break; }
  if is_busy "$victim"; then
    act "SKIP (dipakai proses): $victim"
    rest=(); for f in "${alive[@]}"; do [[ "$f" != "$victim" ]] && rest+=("$f"); done
    alive=("${rest[@]}")
    continue
  fi
  szk=$(du -k "$victim" 2>/dev/null | cut -f1); szk=${szk:-0}
  freed=$((freed + szk)); deleted=$((deleted + 1))
  act "hapus (cap total): $victim"
  [[ $DRY -eq 0 ]] && rm -f "$victim"
  rest=(); for f in "${alive[@]}"; do [[ "$f" != "$victim" ]] && rest+=("$f"); done
  alive=("${rest[@]}")
  totalk=$(du -sk "$LOG_DIR" 2>/dev/null | cut -f1); totalk=${totalk:-0}
done

echo "[trim] selesai: deleted=$deleted truncated=$truncated freed≈$((freed/1024))MB total_logs=$((totalk/1024))MB"
exit 0
