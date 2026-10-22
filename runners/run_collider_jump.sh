#!/usr/bin/env bash
# Self-contained Metal kangaroo (collider_jump) runner with RANDOM SUBRANGE support.
# GPU-only: the walk kernel runs on the M2 GPU; no CPU-based solver helpers.
# Random start + checkpoint hex handled by one quick python3 call per round
# (big-int range math); no persistent helper process while the collider runs.
#
# Behavior (per user request; slot-grid sejak 2026-10-22):
#   - Each TIME window, pick a START_PCT snapped to a fixed grid of JUMP_PCT-sized
#     slots (0..100-JUMP_PCT, 8 decimals).
#   - Collider scans only [START_PCT%, START_PCT%+JUMP_PCT%] of the puzzle range.
#   - After TIME, re-randomize and run again, until a MATCH is found or you stop manually (Ctrl-C).
#   - All used START_PCT values are appended to logs/<NAME>.pct_history.
#   - A PERMANENT checkpoint is kept per puzzle in $B1000/checkpoints/randomColliders<PZ>.js:
#       let randomColliders140 = [
#         {presentage: "3.87650000", hex: "0x..."},
#       ]
#     Dedup key = GRID SLOT (presentage // JUMP_PCT), bukan hex-start persis.
#     Alasan (audit 2026-10-22, snapshot p140): dedup lama exact-start membuat
#     pasangan window overlap terukur ~= ekspektasi kebetulan murni (6650 vs 6649),
#     artinya proteksi anti-tumpang-tindih NOL. Akibatnya satu slot pernah disapu
#     11x sementara ~8% slot tak pernah tersentuh, walau area disapu 257,9% dan
#     coverage union mentok di 92,2%. (Angka slot ikut naik tiap merge remote —
#     jangan kutip ulang tanpa re-audit.) Snap ke tepi slot membuat dua window dari
#     dua slot berbeda MUSTI saling lepas -> kerja GPU tidak pernah dobel, dan slot
#     bebas = satu-satunya target tersisa.
#     CATATAN JUJUR: ini menjamin "kangaroo pernah ditempatkan di tiap slot", BUKAN
#     enumerasi titik-per-titik. main.m menempatkan tame/wild pada jarak ACAK di dalam
#     window (b_rndmax) dan tiap round berakhir via [timeout], bukan dengan menghabiskan
#     window. Slot coverage 100% tetap != pemeriksaan menyeluruh.
#     Entry LAMA (posisi acak, non-rata-tepi) dipetakan ke slot yang memuat start-nya;
#     sisa kiri slot itu (<1 lebar slot) dianggap tercakup. Saat semua slot terpakai
#     runner berhenti dengan "RANGE KOMPLET" — TIDAK pernah jatuh ke pick acak dobel.
#
# Usage: bash run_collider_jump.sh <configs/collider_jump_p<Puzzle>_rnd.conf> [seconds_per_round]
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
B1000="$ROOT/collider"
METAL_DIR="$B1000/tools/metal-kangaroo"
METAL_BIN="${METAL_BIN:-$METAL_DIR/metal-kangaroo}"
LOG_DIR="$B1000/logs"; mkdir -p "$LOG_DIR"

# Anti-sleep: round panjang (TIME=2400 detik) mati kalau Mac tidur.
# caffeinate hidup sepanjang proses metal-kangaroo; kalau binarnya tidak ada
# (mis. CI/Linux) kita jalankan polos — jalan tanpa perlindungan, bukan gagal.
CAFF="$(command -v caffeinate 2>/dev/null || true)"
run_metal() {
  if [[ -n "$CAFF" ]]; then "$CAFF" -i "$@"; else "$@"; fi
}

# --- portable: build the Metal binary for THIS Mac if missing / wrong arch ---
ensure_metal_bin() {
  local need=0
  if [[ ! -x "$METAL_BIN" ]]; then need=1
  elif command -v file >/dev/null 2>&1; then
    file "$METAL_BIN" 2>/dev/null | grep -q "$(uname -m)" || need=1
  fi
  # FIX 2026-09-23: deteksi source LEBIH BARU dari binary. Versi lama cuma cek
  # keberadaan/arch -> fix di main.m tak pernah masuk binary basi (akar "binary
  # stale" audit 2026-09-23, lihat AGENTS.md §13).
  if [[ "$need" -eq 0 ]]; then
    local s
    for s in main.m kangaroo.metal Makefile build.sh; do
      if [[ -f "$METAL_DIR/$s" && "$METAL_DIR/$s" -nt "$METAL_BIN" ]]; then need=1; break; fi
    done
  fi
  if [[ "$need" -eq 1 ]]; then
    echo "[portable] metal-kangaroo binary not usable here; building for $(uname -m)..."
    if bash "$METAL_DIR/build.sh"; then
      echo "[portable] build OK."
    else
      echo "MISSING/UNBUILDABLE binary: $METAL_BIN (run: bash $METAL_DIR/build.sh)"
      exit 2
    fi
  fi
}

# device-aware kang pool when neither env nor config sets KANGS
# Detects GPU type via system_profiler and sizes the pool accordingly.
# The binary (main.m) applies its own cap at dispatch time, but a sane
# default here avoids oversized GPU buffer allocation.
auto_kangs() {
  local gpu_name ram_gb cores k
  # detect GPU name (first Metal GPU found)
  gpu_name="$(system_profiler SPDisplaysDataType 2>/dev/null \
    | grep -m1 'Chipset Model:' | sed 's/.*Chipset Model: *//')" || true
  ram_gb=$(( ($(sysctl -n hw.memsize 2>/dev/null || echo 17179869184) ) / 1073741824 ))
  # GPU-family defaults (matches main.m maxKangs caps)
  case "$gpu_name" in
    *M4*Max*)   k=20000 ;;
    *M4*Pro*)   k=12000 ;;
    *M4*|*M2*)  k=6000  ;;
    *M1*)       k=4096  ;;
    *)          k=$(( ram_gb * 512 )) ;;   # fallback: RAM-based estimate
  esac
  [[ $k -lt 2048 ]] && k=2048
  [[ $k -gt 65536 ]] && k=65536
  echo "$k"
}

CONF="${1:-}"
if [[ -z "$CONF" ]]; then
  echo "Usage: bash $0 <configs/collider_jump_p<Puzzle>_rnd.conf> [seconds_per_round]"
  exit 1
fi
if [[ ! -f "$CONF" ]]; then
  echo "Config not found: $CONF"
  exit 1
fi

get() { grep -E "^$1=" "$CONF" | head -1 | cut -d= -f2-; }
PUZZLE="$(get PUZZLE)"
NAME="$(get NAME)"
DP_BITS="$(get DP_BITS)"
TIME_RAW="$(get TIME)"
TIME="${2:-${TIME_RAW:-6000}}"
JUMP_PCT="$(get JUMP_PCT)"
JUMP_PCT="${JUMP_PCT:-0.1}"

# ONCE mode: when invoked by start-all, run exactly one round per invocation
# (the master loop advances to the next config). When launched directly
# (no COLLIDER_ONCE env), run the continuous random-subrange loop.
if [[ -n "${COLLIDER_ONCE:-}" ]]; then
  ONCE_MODE="ONCE (single round, master-controlled)"
else
  ONCE_MODE="loop (continuous)"
fi

ensure_metal_bin
[[ -x "$METAL_BIN" ]] || { echo "MISSING binary: $METAL_BIN"; exit 2; }

name="${NAME:-p${PUZZLE}_cj}"
log="$LOG_DIR/${name}.metal.log"
PCT_HIST="$LOG_DIR/${name}.pct_history"

# JUMP_PCT like "0.1" -> scaled to 1e-8 ints (8 decimals, matches history).
ip="${JUMP_PCT%%.*}"; fp="${JUMP_PCT#*.}"
fp="${fp}00000000"; fp="${fp:0:8}"
jpE8=$(( 10#$ip * 100000000 + 10#$fp ))

# ---- persistent random-start checkpoint --------------------------------
# Dedup key = HEX subrange; same presentage but different hex => still run.
CKPT_DIR="$B1000/checkpoints"; mkdir -p "$CKPT_DIR"
CKPT="$CKPT_DIR/randomColliders${PUZZLE}.js"

pick_random_start() {
  # prints 2 lines: START_PCT (e.g. "3.87650000") and its lo-hex subrange start.
  # Atau satu baris "RANGE_COMPLETE" kalau semua slot grid sudah pernah dilalui.
  # On first run, seeds the checkpoint from the pct_history so already-scanned
  # subranges are never re-picked. One python3 call per round (~tens of ms).
  python3 - "$CONF" "$CKPT" "$PCT_HIST" "$JUMP_PCT" "$PUZZLE" <<'PY'
import sys, os, re, random
conf, ckpt, hist, jump, puzzle = sys.argv[1:6]

def field(k):
    for ln in open(conf):
        if ln.strip().startswith(k + "="):
            return ln.split("=", 1)[1].strip()
    return ""

S = int(field("START"), 16); E = int(field("END"), 16); R = E - S

def toE8(s):
    if "." in s: i, f = s.split(".", 1)
    else:        i, f = s, ""
    f = (f + "00000000")[:8]
    return int(i) * 100000000 + int(f)

jp = toE8(jump)

def hex_at(e8):
    # FIX 2026-09-21: dulu //100000000 (bug ÷100, hex ckpt salah faktor 100 vs
    # posisi GPU — lihat AGENTS.md §13). Denominator benar = 1e10 (e8 unit pct).
    # Kernel GPU: startOff = 2^(n-1) * pct/100, dan START config = 2^(n-1) → S + pct×R/100.
    x = "%x" % (S + (R * e8) // 10000000000)
    return "0x" + (x.lstrip("0") or "0")

def load_ckpt():
    ents = []
    if os.path.exists(ckpt):
        for ln in open(ckpt):
            m = re.search(r'presentage:\s*"([^"]+)"\s*,\s*hex:\s*"([^"]+)"', ln)
            if m: ents.append((m.group(1), m.group(2)))
    return ents

ents = load_ckpt()

# ---- SLOT GRID (audit 2026-10-22) ----------------------------------------
# Ukuran slot = JUMP_PCT, jadi dua window dari dua slot BERBEDA saling lepas
# secara konstruksi. Sebelumnya dedup hanya cek hex-start persis: pasangan
# overlap terukur ~= ekspektasi kebetulan murni (= nol proteksi), satu slot
# pernah disapu 11x, dan ~8% slot tak pernah tersentuh.
NSLOTS = 10000000000 // jp
used = set()
for _p, _h in ents:
    used.add(toE8(_p) // jp)

# honour historical rounds (logs/<NAME>.pct_history) UNCONDITIONALLY: sebuah
# slot yang pernah dimulai tidak pernah dipilih ulang, walau checkpoint belum
# sempat terisi (round dibunuh di antara append history dan append checkpoint).
hist_hex = []
if os.path.exists(hist):
    for ln in open(hist):
        s = ln.strip()
        if re.fullmatch(r"\d+\.\d+", s):
            e8 = toE8(s)
            if e8 < 10000000000:
                used.add(e8 // jp)
            if e8 <= 10000000000 - jp:
                hist_hex.append((s, hex_at(e8)))

# seed the checkpoint file once (only when empty/missing); atomic via rename.
if not ents:
    with open(ckpt + ".tmp", "w") as f:
        f.write("let randomColliders%s = [\n" % puzzle)
        for p, h in hist_hex:
            f.write('  {presentage: "%s", hex: "%s"},\n' % (p, h))
        f.write("]\n")
    os.replace(ckpt + ".tmp", ckpt)

# pick a FREE slot; start diratakan tepat ke tepi slot -> window tidak mungkin
# tumpang tindih. Tanpa slot bebas = range komplet (bukan fallback acak dobel).
free = [i for i in range(NSLOTS) if i not in used]
if not free:
    sys.stdout.write("RANGE_COMPLETE\n")
    raise SystemExit(0)

slot = random.choice(free)
e8 = slot * jp
sys.stdout.write("%d.%08d\n" % (e8 // 100000000, e8 % 100000000))
sys.stdout.write(hex_at(e8) + "\n")
PY
}

append_checkpoint() {   # $1=presentage  $2=lo-hex  (call after the round ends)
  local lockdir="$CKPT.lock"
  local maxwait=30 waited=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    sleep 1; waited=$((waited+1))
    if [[ $waited -ge $maxwait ]]; then
      echo "[ckpt] WARN: could not acquire lock after ${maxwait}s, proceeding anyway"
      rmdir "$lockdir" 2>/dev/null; break
    fi
  done
  trap 'rmdir "$lockdir" 2>/dev/null' EXIT
  # idempoten: hex yang SUDAH tercatat tidak ditulis ulang. Dua jalur bisa
  # menyentuh round yang sama — _on_stop (TERM/INT di tengah round) dan jalur
  # normal setelah binary keluar — sehingga slot yang sama bisa kecatat dobel
  # dan memakan slot bebas yang sah.
  if grep -qF "hex: \"$2\"" "$CKPT" 2>/dev/null; then
    rmdir "$lockdir" 2>/dev/null; trap - EXIT; return 0
  fi
  local tmp="$CKPT.tmp"
  sed '$d' "$CKPT" > "$tmp"
  printf '  {presentage: "%s", hex: "%s"},\n]\n' "$1" "$2" >> "$tmp"
  mv "$tmp" "$CKPT"
  rmdir "$lockdir" 2>/dev/null
  trap - EXIT
}

echo "=== [$name] random-subrange collider ${ONCE_MODE} (puzzle $PUZZLE, dp $DP_BITS, jump ${JUMP_PCT}%, ${TIME}s/round) ==="

# Flush the CURRENT (killed) round into the permanent checkpoint before exit,
# so this machine — and other computers after git sync — never re-randomize
# the same subrange. PCT/HEX are the live round's values (set in the loop).
_on_stop() {
  if [[ "${_IN_ROUND:-0}" -eq 1 && -n "${PCT:-}" && -n "${HEX:-}" ]]; then
    # pct_history was already appended at round start; only the permanent
    # checkpoint is missing (it is normally written after a clean round end).
    append_checkpoint "$PCT" "$HEX" 2>/dev/null
    echo "[$(date +%FT%T)] killed mid-round: flushed START_PCT=${PCT}% to checkpoint."
  fi
  echo "[$(date +%FT%T)] stopped by user. History: $PCT_HIST"
  exit 0
}
trap _on_stop INT TERM

while :; do
  pick_out="$(pick_random_start)"
  PCT="${pick_out%%$'\n'*}"; HEX="${pick_out#*$'\n'}"
  if [[ "$PCT" == "RANGE_COMPLETE" || -z "$HEX" ]]; then
    echo "[$(date +%FT%T)] [$name] RANGE KOMPLET: semua slot grid (ukuran ${JUMP_PCT}%) sudah pernah dilalui."
    echo "[$(date +%FT%T)] [$name] Tidak ada window baru yang legal — berhenti, bukan pick acak dobel."
    echo "[$(date +%FT%T)] [$name] (catatan: ini = kangaroo pernah ditempatkan di tiap slot, bukan enumerasi titik-per-titik.)"
    break
  fi
  _IN_ROUND=1
  echo "$PCT" >> "$PCT_HIST"
  pi=$(( 10#${PCT%%.*} * 100000000 + 10#${PCT#*.} ))
  end_int=$(( pi + jpE8 ))
  printf '[%s] round start: START_PCT=%s%% subrange=%s (window %s%% .. %d.%08d%%) ckpt=%s\n' \
    "$(date +%FT%T)" "$PCT" "$HEX" "$PCT" $((end_int/100000000)) $((end_int%100000000)) "$CKPT"
  # KANGS priority: env KANGS -> device auto-detect (default, COLLIDER_FIXEDKANGS=1 to force config) -> config KANGS= -> binary default
  RK="${KANGS:-}"
  if [[ -z "$RK" && -z "${COLLIDER_FIXEDKANGS:-}" ]]; then RK="$(auto_kangs)"; fi
  if [[ -z "$RK" ]]; then RK="$(grep -iE "^KANGS=" "$CONF" | head -1 | cut -d= -f2- | tr -d " \r")"; fi
  echo "[kangs] using pool=$RK ($( [[ -n "${KANGS:-}" ]] && echo env || [[ -n "${COLLIDER_FIXEDKANGS:-}" ]] && echo config || echo auto-device ))"
  if [[ -n "$RK" ]]; then
    run_metal "$METAL_BIN" "$CONF" -t "$TIME" -p "$PCT" "$RK" >> "$log" 2>&1
  else
    run_metal "$METAL_BIN" "$CONF" -t "$TIME" -p "$PCT" >> "$log" 2>&1
  fi
  rc=$?
  # round ended (time out OR solved): record the random start permanently.
  append_checkpoint "$PCT" "$HEX"
  _IN_ROUND=0
  if [[ "$rc" -eq 0 ]]; then
    echo "=== [$name] SOLVED rc=0 at START_PCT=${PCT}% ==="
    # ANTI-ZONK: rc=0 juga terjadi saat round timeout NORMAL. Notifikasi MATCH
    # hanya boleh bunyi kalau binary benar-benar mencetak 'SOLVED k = <hex>'.
    SOLVED_LINE="$(grep -m1 'SOLVED k =' "$log" 2>/dev/null)"
    if [[ -n "$SOLVED_LINE" ]]; then
      osascript -e "display notification \"metal-kangaroo ${name} MATCH at ${PCT}% - check ${log}\" with title \"Kangaroo MATCH\"" 2>/dev/null
    else
      echo "[round] rc=0 tanpa 'SOLVED k =' (timeout normal) — bukan match."
    fi
    # ---- auto-sweep: if a private key was found, move the BTC to SWEEP_ADDRESS ----
    if [[ -n "$SOLVED_LINE" ]]; then
      PRIV="$(echo "$SOLVED_LINE" | sed -nE 's/.*SOLVED k = ([0-9a-fA-F]+).*/\1/p')"
      if [[ -n "$PRIV" ]]; then
        # FOUND file is TRACKED in git: runners/sync.sh pushes it to the cloud so
        # every computer sees the found key (the metal log is gitignored).
        printf '%s\n' "$PRIV" >> "$LOG_DIR/FOUND_p${PUZZLE}.txt"
        # RELAY MATCH INSTAN: push seketika + alert HP (jangan tunggu siklus daemon
        # 30 menit) — ledger temuan sampai ke cloud & HP dalam hitungan detik.
        bash "$B1000/runners/sync.sh" push >/dev/null 2>&1 || true
        bash "$B1000/tools/notify_match.sh" "KANGAROO MATCH p${PUZZLE}" "priv=${PRIV}" >/dev/null 2>&1
        SWEEP_DONE="$B1000/tools/sweep/sweep_done.log"
        if grep -q "PUZZLE=$PUZZLE " "$SWEEP_DONE" 2>/dev/null; then
          echo "[sweep] puzzle $PUZZLE already swept (see $SWEEP_DONE); skip."
        else
          echo "[sweep] found priv=$PRIV -> sweeping to ${SWEEP_ADDRESS:-<default>} ..."
          SWEEP_OUT="$LOG_DIR/${name}.sweep.log"
          if python3 "$B1000/tools/sweep/sweep.py" --config "$CONF" --priv "$PRIV" \
               ${SWEEP_ADDRESS:+--sweep "$SWEEP_ADDRESS"} \
               $( [[ -z "${SWEEP_DRYRUN:-}" ]] && echo --confirm ) \
               $( [[ -n "${SWEEP_DRYRUN:-}" ]] && echo --dry-run ) >> "$SWEEP_OUT" 2>&1; then
            echo "[sweep] done (see $SWEEP_OUT)"
            echo "PUZZLE=$PUZZLE ADDR=$name" >> "$SWEEP_DONE"
          else
            echo "[sweep] FAILED (see $SWEEP_OUT) -- priv kept in log for manual sweep"
          fi
        fi
      fi
    else
      echo "[sweep] SOLVED but no 'SOLVED k =' line in log; cannot auto-sweep."
    fi
    break
  fi
  echo "[$(date +%FT%T)] round done rc=$rc, re-randomizing next window..."
  if [[ -n "${COLLIDER_ONCE:-}" ]]; then
    echo "[$(date +%FT%T)] ONCE mode: round complete, returning to master."
    break
  fi
done
echo "=== [$name] loop ended ==="
