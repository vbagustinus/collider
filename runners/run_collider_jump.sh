#!/usr/bin/env bash
# Self-contained Metal kangaroo (collider_jump) runner with RANDOM SUBRANGE support.
# GPU-only: the walk kernel runs on the M2 GPU; no CPU-based solver helpers.
# Random start + checkpoint hex handled by one quick python3 call per round
# (big-int range math); no persistent helper process while the collider runs.
#
# Behavior (per user request):
#   - Each TIME window, pick a random START_PCT (0..100-JUMP_PCT, 8 decimals).
#   - Collider scans only [START_PCT%, START_PCT%+JUMP_PCT%] of the puzzle range.
#   - After TIME, re-randomize and run again, until a MATCH is found or you stop manually (Ctrl-C).
#   - All used START_PCT values are appended to logs/<NAME>.pct_history.
#   - A PERMANENT checkpoint is kept per puzzle in $B1000/checkpoints/randomColliders<PZ>.js:
#       let randomColliders140 = [
#         {presentage: "3.87654321", hex: "0x..."},
#       ]
#     Dedup key = hex subrange. A random start whose hex was already scanned is
#     skipped (fresh random); a start whose hex is NEW is always run, even when
#     the same presentage appears with a different hex in the file (config range
#     changed -> subrange moved). The object is appended/pushed to the checkpoint
#     only after the round ends (time runs out), so it survives restarts.
#
# Usage: bash run_collider_jump.sh <configs/collider_jump_p<Puzzle>_rnd.conf> [seconds_per_round]
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
B1000="$ROOT/collider"
METAL_DIR="$B1000/tools/metal-kangaroo"
METAL_BIN="${METAL_BIN:-$METAL_DIR/metal-kangaroo}"
LOG_DIR="$B1000/logs"; mkdir -p "$LOG_DIR"

# --- portable: build the Metal binary for THIS Mac if missing / wrong arch ---
ensure_metal_bin() {
  local need=0
  if [[ ! -x "$METAL_BIN" ]]; then need=1
  elif command -v file >/dev/null 2>&1; then
    file "$METAL_BIN" 2>/dev/null | grep -q "$(uname -m)" || need=1
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
auto_kangs() {
  local ram_gb k
  ram_gb=$(( ($(sysctl -n hw.memsize 2>/dev/null || echo 17179869184) ) / 1073741824 ))
  k=$(( ram_gb * 1024 ))
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
  # prints 2 lines: START_PCT (e.g. "3.87654321") and its lo-hex subrange start.
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
RANGE = 10000000000 - jp            # max START_PCT in 1e-8 units
if RANGE < 1: RANGE = 1

def hex_at(e8):
    x = "%x" % (S + (R * e8) // 100000000)   # same math the kernel uses
    return "0x" + (x.lstrip("0") or "0")

def load_ckpt():
    ents = []
    if os.path.exists(ckpt):
        for ln in open(ckpt):
            m = re.search(r'presentage:\s*"([^"]+)"\s*,\s*hex:\s*"([^"]+)"', ln)
            if m: ents.append((m.group(1), m.group(2)))
    return ents

ents = load_ckpt()
seen = {h for _, h in ents}

# honour historical rounds (logs/<NAME>.pct_history) UNCONDITIONALLY, not just
# at seed time: a subrange that was ever started is never re-picked, even if the
# checkpoint file is incomplete (e.g. the round was killed between the history
# append and the checkpoint append).
hist_hex = []
hist_seen = set()
if os.path.exists(hist):
    for ln in open(hist):
        s = ln.strip()
        if re.fullmatch(r"\d+\.\d+", s):
            e8 = toE8(s)
            if e8 < RANGE:
                h = hex_at(e8)
                if h not in hist_seen:
                    hist_seen.add(h)
                    seen.add(h)
                    hist_hex.append((s, h))

# seed the checkpoint file once (only when empty/missing); atomic via rename.
if not ents:
    with open(ckpt + ".tmp", "w") as f:
        f.write("let randomColliders%s = [\n" % puzzle)
        for p, h in hist_hex:
            f.write('  {presentage: "%s", hex: "%s"},\n' % (p, h))
        f.write("]\n")
    os.replace(ckpt + ".tmp", ckpt)

# pick a random start whose subrange has never been scanned.
random.seed()
for _ in range(2000000):
    e8 = random.randrange(RANGE)
    h = hex_at(e8)
    if h not in seen:
        print("%d.%08d" % (e8 // 100000000, e8 % 100000000))
        print(h)
        break
else:
    e8 = random.randrange(RANGE)
    print("%d.%08d" % (e8 // 100000000, e8 % 100000000))
    print(hex_at(e8))
PY
}

append_checkpoint() {   # $1=presentage  $2=lo-hex  (call after the round ends)
  local tmp="$CKPT.tmp"
  sed '$d' "$CKPT" > "$tmp"
  printf '  {presentage: "%s", hex: "%s"},\n]\n' "$1" "$2" >> "$tmp"
  mv "$tmp" "$CKPT"
}

echo "=== [$name] random-subrange collider ${ONCE_MODE} (puzzle $PUZZLE, dp $DP_BITS, jump ${JUMP_PCT}%, ${TIME}s/round) ==="

trap 'echo "[$(date +%FT%T)] stopped by user. History: $PCT_HIST"; exit 0' INT TERM

while :; do
  pick_out="$(pick_random_start)"
  PCT="${pick_out%%$'\n'*}"; HEX="${pick_out#*$'\n'}"
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
    "$METAL_BIN" "$CONF" -t "$TIME" -p "$PCT" "$RK" >> "$log" 2>&1
  else
    "$METAL_BIN" "$CONF" -t "$TIME" -p "$PCT" >> "$log" 2>&1
  fi
  rc=$?
  # round ended (time out OR solved): record the random start permanently.
  append_checkpoint "$PCT" "$HEX"
  if [[ "$rc" -eq 0 ]]; then
    echo "=== [$name] SOLVED rc=0 at START_PCT=${PCT}% ==="
    if [[ -s "$log" ]]; then
      osascript -e "display notification \"metal-kangaroo ${name} MATCH at ${PCT}% - check ${log}\" with title \"Kangaroo MATCH\"" 2>/dev/null
    fi
    # ---- auto-sweep: if a private key was found, move the BTC to SWEEP_ADDRESS ----
    SOLVED_LINE="$(grep -m1 'SOLVED k =' "$log" 2>/dev/null)"
    if [[ -n "$SOLVED_LINE" ]]; then
      PRIV="$(echo "$SOLVED_LINE" | sed -nE 's/.*SOLVED k = ([0-9a-fA-F]+).*/\1/p')"
      if [[ -n "$PRIV" ]]; then
        SWEEP_DONE="$B1000/tools/sweep/sweep_done.log"
        if grep -q "PUZZLE=$PUZZLE " "$SWEEP_DONE" 2>/dev/null; then
          echo "[sweep] puzzle $PUZZLE already swept (see $SWEEP_DONE); skip."
        else
          echo "[sweep] found priv=$PRIV -> sweeping to ${SWEEP_ADDRESS:-<default>} ..."
          SWEEP_OUT="$LOG_DIR/${name}.sweep.log"
          if python3 "$B1000/tools/sweep/sweep.py" --config "$CONF" --priv "$PRIV" \
               ${SWEEP_ADDRESS:+--sweep "$SWEEP_ADDRESS"} \
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
