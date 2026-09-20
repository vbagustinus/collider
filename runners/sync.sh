#!/usr/bin/env bash
# runners/sync.sh — shared git sync helper for the collider repo.
#
# Sourced by run_all_colliders.sh (and usable standalone):
#   source "$B1000/runners/sync.sh"
#
# Public functions:
#   sync_pull        — pull latest from origin/main (progress from other computers)
#   sync_push        — commit + push checkpoints / pct_history / FOUND files
#   sync_normalize   — normalize (dedup + sort) all checkpoint files
#   sync_daemon      — periodic pull+push while the sweep master runs
#   sync_daemon_stop — stop the daemon + final flush push
#
# Multi-computer safe:
#   - Only progress files are committed: checkpoints/randomColliders*.js,
#     logs/*.pct_history, logs/FOUND_*.txt (found keys).
#   - .gitattributes sets merge=union on those files, so two computers appending
#     lines never produce conflict markers.
#   - sync_pull stashes ONLY managed progress files; user code edits are untouched.
#   - sync_push holds a lock dir so concurrent pushes (round-end + daemon) serialize.

_COL_SYNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${COL_ROOT:=$(cd "$_COL_SYNC_DIR/.." && pwd)}"
COL_GIT="git -C $COL_ROOT"

# Register the union merge driver (idempotent). The driver comes from the cloud
# (tools/merge_progress_union.py): semantic dedup by hex/pct, new entries
# inserted before the closing ']', and stale conflict markers dropped. Without
# it git falls back to a plain 3-way merge for progress files.
if [[ -f "$COL_ROOT/tools/merge_progress_union.py" ]]; then
  $COL_GIT config merge.progressUnion.driver "python3 '$COL_ROOT/tools/merge_progress_union.py' %O %A %B"
fi

_col_log() { echo "[$(date +%FT%T)] [sync] $*"; }

# ---- checkpoint normalization ------------------------------------------
# Files contain JS-ish arrays:
#   let randomColliders145 = [
#     {presentage: "3.87654321", hex: "0x..."},
#   ]
# Normalize = dedupe entry lines and sort by presentage. Idempotent,
# atomic (tmp + rename), safe under concurrency.
sync_normalize() {
  python3 - "$COL_ROOT/checkpoints" <<'PY'
import os, re, sys

ckpt_dir = sys.argv[1]
if not os.path.isdir(ckpt_dir):
    sys.exit(0)

for fn in os.listdir(ckpt_dir):
    if not (fn.startswith("randomColliders") and fn.endswith(".js")):
        continue
    path = os.path.join(ckpt_dir, fn)
    try:
        lines = open(path).read().splitlines()
    except OSError:
        continue
    head, ents = [], []
    for ln in lines:
        s = ln.strip()
        if s.startswith("let "):
            head.append(ln)
        elif s == "]":
            pass  # footer
        elif s.startswith(("<<<<<<<", "=======", ">>>>>>>")):
            continue  # stale conflict markers from an old bad merge
        elif s:
            ents.append(s)
    if not head:
        head = ["let %s = [" % fn[:-3]]
    seen, out = set(), []
    def key(e):
        m = re.search(r'presentage:\s*"(\d+)\.(\d+)"', e)
        if not m:
            return (0, 0, e)
        return (int(m.group(1)), int((m.group(2) + "00000000")[:8]), e)
    for e in sorted(ents, key=key):
        if e not in seen:
            seen.add(e)
            out.append(e if e.startswith("  ") else "  " + e)
    with open(path + ".tmp", "w") as f:
        f.write("\n".join(head + out + ["]"]) + "\n")
    os.replace(path + ".tmp", path)
PY
  return 0
}

# ---- pull ----------------------------------------------------------------
sync_pull() {
  local stashed=0 n0 n1
  # stash ONLY managed progress files — never the user's code edits.
  # NOTE: paths are anchored to the REPO ROOT (git -C), and in this repo
  # progress lives under collider/.
  # Compare stash-list count before/after: 'stash push' exits 0 even when it
  # saves nothing, and popping then could pop a PRE-EXISTING user stash.
  n0=$($COL_GIT stash list 2>/dev/null | wc -l | tr -d ' ')
  $COL_GIT stash push -m "sync: auto-stash progress before pull $(date +%FT%T)" \
      -- checkpoints logs/FOUND_*.txt logs/*.pct_history >/dev/null 2>&1
  n1=$($COL_GIT stash list 2>/dev/null | wc -l | tr -d ' ')
  [[ "$n1" -gt "$n0" ]] && stashed=1
  if ! $COL_GIT pull --rebase origin main >/dev/null 2>&1; then
    if ! $COL_GIT diff --quiet 2>/dev/null || ! $COL_GIT diff --cached --quiet 2>/dev/null; then
      _col_log "pull skipped: uncommitted code changes present (progress stashed; code untouched)"
    else
      _col_log "WARN: pull failed (offline?); continuing with local state"
    fi
  fi
  if [[ "$stashed" -eq 1 ]]; then
    $COL_GIT stash pop >/dev/null 2>&1 || _col_log "WARN: stash pop had conflicts; resolve manually with 'git -C $COL_ROOT status'"
  fi
  sync_normalize
  # normalization may itself change files — commit that quietly so the tree
  # stays clean for the next pull.
  $COL_GIT add checkpoints logs 2>/dev/null
  if ! $COL_GIT diff --cached --quiet 2>/dev/null; then
    $COL_GIT commit -m "sync: normalize checkpoints after pull $(date +%FT%T)" >/dev/null 2>&1 || true
  fi
  return 0
}

# ---- push ----------------------------------------------------------------
sync_push() {
  local lock="$COL_ROOT/.git/sync_push.lock"
  local waited=0
  until mkdir "$lock" 2>/dev/null; do
    sleep 1; waited=$((waited+1))
    if [[ $waited -ge 60 ]]; then
      _col_log "another push in progress; skipping (retried on next cycle)."
      return 0
    fi
  done
  sync_normalize
  # stage only files that actually exist — a git add whose pathspec matches
  # NOTHING (e.g. no FOUND_*.txt yet) aborts entirely, staging zero files.
  (
    shopt -s nullglob
    cand=( "$COL_ROOT"/checkpoints/randomColliders*.js \
           "$COL_ROOT"/logs/*.pct_history \
           "$COL_ROOT"/logs/FOUND_*.txt )
    files=()
    for f in "${cand[@]}"; do [[ -f "$f" ]] && files+=("$f"); done
    (( ${#files[@]} > 0 )) && $COL_GIT add -- "${files[@]}"
  )
  # commit uncommitted progress (if any). Pre-existing LOCAL COMMITS that are
  # simply unpushed are handled by the rev-list check below.
  if ! $COL_GIT diff --cached --quiet 2>/dev/null; then
    $COL_GIT commit -m "sync: update checkpoints + pct_history $(date +%Y-%m-%d_%H:%M)" >/dev/null 2>&1 || true
  fi
  # push when there is ANY unpushed local commit (new or pre-existing)
  local unpushed
  if ! $COL_GIT rev-parse --verify -q origin/main >/dev/null 2>&1; then
    unpushed=yes                       # upstream ref unknown yet — try push
  else
    unpushed="$($COL_GIT rev-list origin/main..main --max-count=1 2>/dev/null)"
  fi
  if [[ -z "$unpushed" ]]; then
    rmdir "$lock" 2>/dev/null
    return 0
  fi
  if $COL_GIT push origin main >/dev/null 2>&1; then
    _col_log "pushed progress to origin/main."
  else
    _col_log "push rejected; pulling remote progress and retrying..."
    rmdir "$lock" 2>/dev/null
    sync_pull
    if $COL_GIT push origin main >/dev/null 2>&1; then
      _col_log "pushed after rebase."
    else
      _col_log "WARN: push still failed; will retry on next sync cycle."
    fi
    return 0
  fi
  rmdir "$lock" 2>/dev/null
  return 0
}

# ---- periodic daemon ------------------------------------------------------
# Writes a pid file so stop-all from ANOTHER shell can terminate it.
sync_daemon() {
  local interval="${COL_SYNC_PUSH_S:-${KH_SYNC_PUSH_S:-300}}"
  local pf="$COL_ROOT/logs/.pids/sync_daemon.pid"
  mkdir -p "$(dirname "$pf")"
  if [[ -f "$pf" ]] && kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null; then
    _col_log "sync daemon already running (pid $(cat "$pf"))."
    return 0
  fi
  (
    trap 'exit 0' TERM INT
    while :; do
      sleep "$interval" & SW=$!
      wait "$SW" 2>/dev/null || true   # interrupted instantly by TERM
      sync_pull
      sync_push
    done
  ) &
  COL_SYNC_DAEMON_PID=$!
  echo "$COL_SYNC_DAEMON_PID" > "$pf"
  disown 2>/dev/null || true
  _col_log "sync daemon started (pid $COL_SYNC_DAEMON_PID, every ${interval}s)."
}

sync_daemon_stop() {
  local pf="$COL_ROOT/logs/.pids/sync_daemon.pid"
  local dpid
  dpid="$(cat "$pf" 2>/dev/null || true)"
  if [[ -n "$dpid" ]] && kill -0 "$dpid" 2>/dev/null; then
    kill -TERM "$dpid" 2>/dev/null
    _col_log "sync daemon stopped (pid $dpid)."
  fi
  rm -f "$pf"
  # final flush on shutdown
  sync_push
}
