#!/usr/bin/env bash
# run_all_colliders.sh — single master control for the b1000 Metal collider sweep.
#
#   run_all_colliders.sh start-all [seconds_per_round] [kangs]
#       - stop leftover collider processes (if any), then launch ONE master loop
#         that sweeps ALL ENABLED configs/collider_jump_*_rnd.conf, one GPU
#         process at a time (sequential) to avoid M2 GPU oversubscription.
#   run_all_colliders.sh stop-all      - terminate THE MASTER + runner + Metal
#         binary + any leftover GPU process. Waits, force-kills, and verifies
#         that nothing collider-related remains.
#   run_all_colliders.sh status         - show master + ruffian processes + one
#         line per config.
#
# This file is self-contained: start-all runs this same script in `--loop` mode,
# so the PID file always refers to the real master process (no wrapper indirection).

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
B1000="$ROOT/collider"
RUNNER="$B1000/runners/run_collider_jump.sh"
CONF_DIR="$B1000/configs"
LOG_DIR="$B1000/logs"; mkdir -p "$LOG_DIR"
PID_DIR="$LOG_DIR/.pids"; mkdir -p "$PID_DIR"

MASTER_PID="$PID_DIR/sweep_master.pid"
STOP_FILE="$PID_DIR/sweep_STOP"
SCHED_LOG="$LOG_DIR/sweep_scheduler.log"

cmd="${1:-status}"

get_field() { grep -iE "^$1=" "$2" | head -1 | cut -d= -f2- | tr -d ' \r'; }

alive() { local p="${1:-}"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }

master_pid() { cat "$MASTER_PID" 2>/dev/null; }

# All pids we consider "ours": master, runner bash, metal binary.
# NOTE: patterns must NOT appear in this script's own cmdline (they don't).
collider_pids() {
  pgrep -f "collider/runners/run_collider_jump.sh" 2>/dev/null
  pgrep -f "collider/tools/metal-kangaroo/metal-kangaroo" 2>/dev/null
  local m; m="$(master_pid)"; alive "$m" && echo "$m"
}

stop_everything() {
  # grace + force, shared by stop-all and start-all's cleanup
  local m
  rm -f "$STOP_FILE" 2>/dev/null
  m="$(master_pid)"; if alive "$m"; then kill -TERM "$m" 2>/dev/null; fi
  pkill -TERM -f "run_collider_jump.sh" 2>/dev/null
  pkill -TERM -f "collider/tools/metal-kangaroo/metal-kangaroo" 2>/dev/null
  sleep 2
  pkill -9 -f "run_collider_jump.sh" 2>/dev/null
  pkill -9 -f "collider/tools/metal-kangaroo/metal-kangaroo" 2>/dev/null
  rm -f "$MASTER_PID" 2>/dev/null
  sleep 1
}

### Internal master loop -----------------------------------------------
if [[ "${1:-}" == "--loop" ]]; then
  ROUND="${2:-600}"
  KANGS="${3:-}"
  rm -f "$STOP_FILE"                      # never block a fresh sweep
  echo "=== [sweep] master pid $$ @ $(date +%FT%T), round=${ROUND}s ==="
  PASS=0
  while :; do
    PASS=$((PASS+1))
    echo "=== [sweep] PASS $PASS @ $(date +%FT%T) ==="
    for CONF in "$CONF_DIR"/collider_jump_*_rnd.conf; do
      [[ -f "$CONF" ]] || continue
      [[ "$(get_field ENABLED "$CONF")" == "1" ]] || continue
      if [[ -f "$STOP_FILE" ]]; then echo "=== [sweep] STOP flag, stopping."; rm -f "$STOP_FILE"; exit 0; fi
      NAME="$(get_field NAME "$CONF")"; NAME="${NAME%.metal}"
      echo "  >>> [sweep] $(basename "$CONF") round=${ROUND}s ..."
      if [[ -n "$KANGS" ]]; then
        COLLIDER_ONCE=1 KANGS="$KANGS" bash "$RUNNER" "$CONF" "$ROUND"
      else
        COLLIDER_ONCE=1 bash "$RUNNER" "$CONF" "$ROUND"
      fi
      echo "  <<< [sweep] done $(basename "$CONF")"
      if [[ -f "$STOP_FILE" ]]; then echo "=== [sweep] STOP during run, stopping."; rm -f "$STOP_FILE"; exit 0; fi
    done
  done
fi

case "$cmd" in

  start-all)
    ROUND="${2:-600}"
    KANGS="${3:-}"
    if alive "$(master_pid)"; then
      echo "colliders ALREADY running (pid $(master_pid)). Re-launching cleanly..."
      stop_everything
    elif [[ -n "$(collider_pids)" ]]; then
      echo "detected leftover collider processes; cleaning up before start."
      stop_everything
    else
      rm -f "$PID_DIR"/sweep_*.pid 2>/dev/null || true
    fi
    rm -f "$STOP_FILE"
    bash "$0" --loop "$ROUND" "$KANGS" >>"$SCHED_LOG" 2>&1 < /dev/null &
    echo "$!" > "$MASTER_PID"
    disown 2>/dev/null || true
    sleep 1
    if alive "$(master_pid)"; then
      tools_pids="$(pgrep -f 'collider/tools/metal-kangaroo/metal-kangaroo' | tr '\n' ' ')"
      echo "=== colliders STARTED (master pid $(master_pid)) ==="
      echo "Round: ${ROUND}s/config | sweeping all ENABLED collider_jump_*_rnd.conf"
      echo "Log: $SCHED_LOG"
      echo "--- last lines ---"; tail -n 3 "$SCHED_LOG" 2>/dev/null
      exit 0
    fi
    echo "master failed to launch; log tail:"; tail -n 5 "$SCHED_LOG" 2>/dev/null
    exit 1
    ;;

  stop-all)
    echo "=== stopping ALL collider processes ==="
    rm -f "$STOP_FILE" 2>/dev/null   # ensure a clean flag state
    m="$(master_pid)"; if alive "$m"; then kill -TERM "$m" 2>/dev/null; fi
    pkill -TERM -f "run_collider_jump.sh" 2>/dev/null
    pkill -TERM -f "collider/tools/metal-kangaroo/metal-kangaroo" 2>/dev/null
    sleep 2
    pkill -9 -f "run_collider_jump.sh" 2>/dev/null
    pkill -9 -f "collider/tools/metal-kangaroo/metal-kangaroo" 2>/dev/null
    rm -f "$MASTER_PID" 2>/dev/null
    sleep 1
    leftover="$(collider_pids)"
    if [[ -n "$leftover" ]]; then
      echo "WARN still running: $(echo $leftover | tr '\n' ' ')"
      exit 1
    fi
    echo "all collider processes stopped (0 left)."
    exit 0
    ;;

  status)
    m="$(master_pid)"
    if alive "$m"; then
      echo "=== colliders: RUNNING (master pid $m) ==="
    else
      echo "=== colliders: IDLE ==="
    fi
    echo
    echo "GPU processes:"
    pgrep -fl "collider/tools/metal-kangaroo/metal-kangaroo" 2>/dev/null || echo "  (none)"
    echo
printf "%-5s %-8s %-8s %-6s %-10s %-6s %s\n" "#Puz" "ENABLED" "CONF" "state" "scan%" "ckpt" "subrange (live / last history)"
    for CONF in "$CONF_DIR"/collider_j*_rnd.conf; do
      [[ -f "$CONF" ]] || continue
      ENABLED="$(get_field ENABLED "$CONF")"
      NAME="$(get_field NAME "$CONF")"
      PUZ="$(get_field PUZZLE "$CONF")"
      JUMP="$(get_field JUMP_PCT "$CONF")"; JUMP="${JUMP:-0.1}"
      CKPT_FILE="$B1000/checkpoints/randomColliders${PUZ}.js"
      ckpt_n="0"
      [[ -f "$CKPT_FILE" ]] && ckpt_n="$(grep -c 'presentage:' "$CKPT_FILE" 2>/dev/null)"
      line=$(pgrep -fl "collider/tools/metal-kangaroo/metal-kangaroo $CONF" 2>/dev/null | head -1)
      if [[ -n "$line" ]]; then
        state="ACTIVE"
        pctval=$(echo "$line" | sed -nE 's/.*-p ([0-9.]+).*/\1/p')
      else
        state="idle"
        hist="$LOG_DIR/${NAME}.pct_history"
        pctval="-"; [[ -s "$hist" ]] && pctval="$(tail -1 "$hist" | tr -d ' \r')"
      fi
      if [[ "$pctval" =~ ^[0-9.]+$ ]]; then
        hexrange="$(python3 - "$CONF" "$pctval" "$JUMP" <<'PY'
import sys
conf,pct,jump=sys.argv[1],sys.argv[2],sys.argv[3]
def field(k):
    for ln in open(conf):
        if ln.strip().startswith(k+"="):
            return ln.split("=",1)[1].strip()
    return ""
S=int(field("START"),16); E=int(field("END"),16); R=E-S
def toE8(s):                      # "9.1424" -> 900000000+14240000 in 1e-8 units
    if "." in s: i,f=s.split(".",1)
    else:        i,f=s,""
    f=(f+"00000000")[:8]
    return int(i)*100000000 + int(f)
def at_e8(e8):                    # exact big-int: R * e8 / 1e8, same math the kernel uses
    return (R*e8)//100000000
p=toE8(pct); jp=toE8(jump)
lo=S+at_e8(p); hi=S+at_e8(p+jp)
def hx(v):
    x="%x"%v
    x=x.lstrip("0") or "0"
    return "0x"+x
print(hx(lo)); print(hx(hi))
PY
)"
        lo="$(echo "$hexrange" | sed -n 1p)"; hi="$(echo "$hexrange" | sed -n 2p)"
      else
        lo="--"; hi="--"
      fi
      printf "p%-6s %-8s %-8s %-6s %-10s %-6s %s .. %s\n" "$PUZ" "$ENABLED" "$NAME" "$state" "${pctval}%" "$ckpt_n" "$lo" "$hi"
    done
    exit 0
    ;;

  *)
    echo "Usage: run_all_colliders.sh {start-all|stop-all|status} [seconds_per_round] [kangs]"
    exit 1
    ;;

esac