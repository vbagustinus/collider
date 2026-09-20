#!/usr/bin/env bash
# runners/sync.sh — shared git sync helper for the collider repo.
#
# Sourced by run_all_colliders.sh (and usable standalone):
#   source "$B1000/runners/sync.sh"
#
# Public functions:
#   sync_pull        — pull latest from origin/main (progress from other computers);
#                      falls back to merge --autostash when the tree stays dirty
#                      with NON-progress files (rebase refuses to run then)
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
#   - sync_pull AND sync_push share one lock dir (sync_push.lock, contains the
#     owner's $BASHPID): dead owner or lock older than 10 min => stale => removed.
#     Without that, one crash mid-push would block sync forever.
#   - Our stash entries are popped BY MESSAGE, never blindly from the stack top,
#     so a user stash created meanwhile is never popped by us.
#   - Leftover rebase/merge state (conflict from an earlier cycle) is aborted
#     automatically at pull start/end — otherwise every later git command fails.
#   - GIT_TERMINAL_PROMPT=0 + ssh BatchMode: unattended daemon never hangs on a
#     credential prompt.

_COL_SYNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${COL_ROOT:=$(cd "$_COL_SYNC_DIR/.." && pwd)}"
COL_GIT="git -C $COL_ROOT"

# Unattended daemon: NEVER prompt for credentials (http) — a prompt hangs the
# daemon forever while it holds the lock. ssh: BatchMode fails fast instead of
# asking for a passphrase. User's own GIT_SSH_COMMAND is respected.
export GIT_TERMINAL_PROMPT=0
if [[ -z "${GIT_SSH_COMMAND:-}" ]]; then
  export GIT_SSH_COMMAND="ssh -oBatchMode=yes"
fi

# Register the union merge driver (idempotent). The driver comes from the cloud
# (tools/merge_progress_union.py): semantic dedup by hex/pct, new entries
# inserted before the closing ']', and stale conflict markers dropped. Without
# it git falls back to a plain 3-way merge for progress files.
if [[ -f "$COL_ROOT/tools/merge_progress_union.py" ]]; then
  $COL_GIT config merge.progressUnion.driver "python3 '$COL_ROOT/tools/merge_progress_union.py' %O %A %B"
fi

_col_log() { echo "[$(date +%FT%T)] [sync] $*"; }

# ---- lock -----------------------------------------------------------------
# One lock dir shared by sync_pull and sync_pull+push cycles. Contains `pid`
# with the owner's process id. PORTABLE pid: macOS /bin/bash 3.2 has no
# $BASHPID (bash>=4) — under `set -u` that explodes with "unbound variable"
# and kills e.g. the stop-all final flush. Trick: `sh -c 'echo $PPID'` gives
# the CALLER's pid on every bash version, also inside daemon subshells where
# $$ still points at the long-gone parent. Stale detection: owner pid dead =>
# remove; or lock older than 600s (covers pid reuse and a crash before the
# pid file was written).
_col_lock_take() { # $1 = timeout seconds; return 0 if lock acquired
  local lock="$COL_ROOT/.git/sync_push.lock" waited=0 owner owner2 mtime age mypid
  until mkdir "$lock" 2>/dev/null; do
    owner=$(cat "$lock/pid" 2>/dev/null)
    if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then
      owner2=$(cat "$lock/pid" 2>/dev/null)
      if [[ "$owner2" == "$owner" ]]; then
        _col_log "stale lock (owner $owner sudah mati); dihapus."
        rm -rf "$lock"
        continue
      fi
    fi
    mtime=$(stat -f %m "$lock/pid" 2>/dev/null || stat -c %Y "$lock/pid" 2>/dev/null || echo 0)
    age=$(( $(date +%s) - mtime ))
    if (( age > 600 )); then
      _col_log "stale lock (umur ${age}s, owner ${owner:-?}); dihapus."
      rm -rf "$lock"
      continue
    fi
    sleep 1; waited=$((waited+1))
    if (( waited >= $1 )); then return 1; fi
  done
  mypid=$(sh -c 'echo $PPID' 2>/dev/null)
  [[ "$mypid" =~ ^[0-9]+$ ]] || mypid=$$
  echo "$mypid" > "$lock/pid"
  return 0
}
_col_lock_release() { rm -rf "$COL_ROOT/.git/sync_push.lock" 2>/dev/null; }

# ---- root_agents.md auto-refresh -------------------------------------------
# "Kebiasaan otomatis": root_agents.md (snapshot AGENTS.md induk project)
# di-refresh dari ../AGENTS.md tiap siklus push — kalau file induk berubah,
# snapshot ikut commit sync berikutnya tanpa langkah manual.
# Syarat: repo ini clone sebelahan dgn repo lain + AGENTS.md induk ada di
# atasnya. Kalau tidak, skip diam-diam (snapshot terakhir tetap valid; mesin
# yang punya layout sibling akan mem-push versi terbaru ke cloud).
_col_root_agents_refresh() {
  local up="$COL_ROOT/../AGENTS.md" dst="$COL_ROOT/root_agents.md"
  [[ -f "$up" ]] || return 0
  [[ -f "$dst" ]] || return 0
  $COL_GIT ls-files --error-unmatch -- root_agents.md >/dev/null 2>&1 || return 0
  cmp -s "$up" "$dst" && return 0
  cp "$up" "$dst"
  $COL_GIT add root_agents.md
  if ! $COL_GIT diff --cached --quiet 2>/dev/null; then
    $COL_GIT commit -m "root_agents.md: auto-refresh from ../AGENTS.md $(date +%Y-%m-%d_%H:%M)" >/dev/null 2>&1 || true
    _col_log "root_agents.md di-refresh dari ../AGENTS.md (commit otomatis)."
  fi
  return 0
}

# Pop only OUR stash entries (message "sync: auto-stash progress before pull"),
# topmost first, by ref — never the stack top blindly. A user stash that sits
# above ours (or below) is never touched. Called while holding the lock, so
# two sync_pulls cannot interleave stash pushes/pops.
_col_stash_pop_ours() { # $1 = n0 (baseline stash count from before our pushes)
  local n0=$1 ref subj entry
  while (( $($COL_GIT stash list 2>/dev/null | wc -l | tr -d ' ') > n0 )); do
    ref=""
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      ref="${entry%% *}"
      subj="${entry#* }"
      # %gs = reflog subject, bentuknya "On <branch>: <pesan>" — match substring
      if [[ "$subj" == *"sync: auto-stash"* ]]; then break; fi
      ref=""
    done < <($COL_GIT stash list --format='%gd %gs' 2>/dev/null)
    if [[ -z "$ref" ]]; then
      _col_log "WARN: stash tersisa bukan milik sync; dibiarkan (cek 'git -C $COL_ROOT stash list')"
      break
    fi
    if ! $COL_GIT stash pop "$ref" >/dev/null 2>&1; then
      _col_log "WARN: stash pop conflict ($ref); perubahan aman di stash — cek 'git -C $COL_ROOT stash list'"
      break
    fi
  done
}

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
  # serialisasi dulu: sync_pull & sync_push tidak boleh jalan bareng —
  # baseline stash (n0) dan pop-ours bisa saling menginjak antar proses.
  if ! _col_lock_take 60; then
    _col_log "sync_pull: sync lain pegang lock; skip cycle ini."
    return 0
  fi
  # bersihkan state merge/rebase TERTINGGAL (mis. konflik dari cycle lama atau
  # operasi manual yang tidak diselesaikan) — kalau dibiarkan, SEMUA command
  # git berikutnya gagal dan sync macet permanen. Harus SETELAH lock didapat,
  # jangan sampai meng-abort rebase milik sync lain yang sedang jalan.
  if [[ -d "$COL_ROOT/.git/rebase-merge" || -d "$COL_ROOT/.git/rebase-apply" ]] \
     || $COL_GIT rev-parse -q --verify REBASE_HEAD >/dev/null 2>&1; then
    $COL_GIT rebase --abort >/dev/null 2>&1 || true
    _col_log "WARN: rebase tertinggal di-abort otomatis (state cycle lama)."
  fi
  if $COL_GIT rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    $COL_GIT merge --abort >/dev/null 2>&1 || true
    _col_log "WARN: merge tertinggal di-abort otomatis (state cycle lama)."
  fi
  # Managed progress paths that EXIST right now. A pathspec containing a glob
  # that matches NOTHING (e.g. logs/FOUND_*.txt before any find) makes the
  # whole 'git stash push' FAIL — stashing zero files (same trap as git add).
  local paths=() f n0 n1 attempt ok=0 err="" dirty=0 merged=0
  for f in "$COL_ROOT"/checkpoints/randomColliders*.js \
           "$COL_ROOT"/logs/*.pct_history \
           "$COL_ROOT"/logs/FOUND_*.txt; do
    [[ -f "$f" ]] && paths+=("${f#"$COL_ROOT"/}")
  done
  # stash ONLY managed progress files — never the user's code edits.
  # Compare stash-list count before/after: 'stash push' exits 0 even when it
  # saves nothing, and popping then could pop a PRE-EXISTING user stash.
  n0=$($COL_GIT stash list 2>/dev/null | wc -l | tr -d ' ')
  if (( ${#paths[@]} > 0 )); then
    $COL_GIT stash push -m "sync: auto-stash progress before pull $(date +%FT%T)" \
        -- "${paths[@]}" >/dev/null 2>&1
    n1=$($COL_GIT stash list 2>/dev/null | wc -l | tr -d ' ')
  fi
  # pull --rebase, up to 3 attempts: active runners keep appending progress
  # between our stash and the pull, briefly dirtying the tree again.
  for attempt in 1 2 3; do
    dirty=0
    $COL_GIT diff --quiet 2>/dev/null || dirty=1
    $COL_GIT diff --cached --quiet 2>/dev/null || dirty=1
    if (( dirty && ${#paths[@]} > 0 )); then
      # re-stash what the runners just wrote (managed progress files only)
      $COL_GIT stash push -m "sync: auto-stash progress before pull (retry $attempt) $(date +%FT%T)" \
          -- "${paths[@]}" >/dev/null 2>&1
      n1=$($COL_GIT stash list 2>/dev/null | wc -l | tr -d ' ')
    fi
    if err="$($COL_GIT pull --rebase origin main 2>&1 >/dev/null)"; then ok=1; break; fi
    # FALLBACK: tree kotor karena file NON-progress (kode/config) tidak bisa
    # di-stash oleh kita. pull --rebase menolak jalan selamanya -> gunakan
    # merge --autostash (union driver menangani overlap progress tanpa
    # konflik; rebase multi sync-commit rawan nyangkut, lihat AGENTS.md).
    if [[ "$err" == *"unstaged changes"* ]] && (( attempt == 3 )); then
      merged=1
      if $COL_GIT pull --no-rebase --autostash origin main >/dev/null 2>&1; then
        ok=1
        _col_log "pull via merge --autostash (tree kotor non-progress)."
        break
      fi
      $COL_GIT merge --abort >/dev/null 2>&1 || true   # jangan tinggalkan state merge
    fi
    sleep 2
  done
  if (( ! ok )); then
    # jangan pernah tinggalkan rebase/merge in-progress yang mengunci cycle
    # berikutnya (mis. konflik di file non-progress). Progres lokal aman:
    # abort hanya membuang state operasi yang gagal, bukan commit.
    $COL_GIT rebase --abort >/dev/null 2>&1 || true
    $COL_GIT merge --abort >/dev/null 2>&1 || true
    if (( dirty )); then
      if (( merged )); then
        _col_log "WARN: merge --autostash fallback gagal (perubahan kotor mungkin tersimpan di 'git stash list'); err: ${err:0:140}"
      else
        _col_log "pull skipped: tree masih kotor (runners menulis progress terus); err: ${err:0:140}"
      fi
    else
      _col_log "WARN: pull gagal (offline?): ${err:0:140}"
    fi
  fi
  # restore exactly the stash entries WE created (by message), never user stashes
  _col_stash_pop_ours "$n0"
  sync_normalize
  # normalization may itself change files — commit that quietly so the tree
  # stays clean for the next pull. Stage ONLY managed progress files.
  (
    shopt -s nullglob
    cand=( "$COL_ROOT"/checkpoints/randomColliders*.js \
           "$COL_ROOT"/logs/*.pct_history \
           "$COL_ROOT"/logs/FOUND_*.txt )
    files=()
    for f in "${cand[@]}"; do [[ -f "$f" ]] && files+=("$f"); done
    (( ${#files[@]} > 0 )) && $COL_GIT add -- "${files[@]}"
  )
  if ! $COL_GIT diff --cached --quiet 2>/dev/null; then
    $COL_GIT commit -m "sync: normalize checkpoints after pull $(date +%FT%T)" >/dev/null 2>&1 || true
  fi
  # merge --autostash yang pop-nya konflik meninggalkan file UNMERGED (UU)
  # milik USER plus entry stash 'autostash' (dipertahankan git agar tak hilang).
  # JANGAN pernah disentuh otomatis — cukup petunjuk pemulihan yang jelas.
  if ! $COL_GIT diff --quiet --diff-filter=U 2>/dev/null; then
    _col_log "WARN: ada file UNMERGED (UU) — sisa konflik autostash/merge di file non-progress."
    _col_log "      pulihkan manual: resolve file → 'git add <file>' → lanjutkan/abort operasi → 'git stash drop' entry 'autostash'."
  fi
  _col_lock_release
  return 0
}

# ---- push ----------------------------------------------------------------
sync_push() {
  if ! _col_lock_take 60; then
    _col_log "another push in progress; skipping (retried on next cycle)."
    return 0
  fi
  _col_root_agents_refresh
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
    _col_lock_release
    return 0
  fi
  if $COL_GIT push origin main >/dev/null 2>&1; then
    _col_log "pushed progress to origin/main."
    _col_lock_release
    return 0
  fi
  # push gagal: bedakan NON-FF (remote maju) dari offline/auth SEBELUM mengambil
  # tindakan — kalau offline, sync_pull hanya buang waktu + log menyesatkan.
  if ! $COL_GIT fetch origin main >/dev/null 2>&1; then
    _col_log "WARN: push+fetch gagal (offline/auth?); will retry on next sync cycle."
    _col_lock_release
    return 0
  fi
  if $COL_GIT merge-base --is-ancestor origin/main main >/dev/null 2>&1; then
    # fast-forward masih mungkin — kegagalan pertama hanya transient/fluke
    if $COL_GIT push origin main >/dev/null 2>&1; then
      _col_log "pushed progress to origin/main."
    else
      _col_log "WARN: push still failed; will retry on next sync cycle."
    fi
    _col_lock_release
    return 0
  fi
  _col_log "push rejected (non-FF); pulling remote progress and retrying..."
  _col_lock_release
  sync_pull
  if ! _col_lock_take 60; then
    _col_log "WARN: lock sibuk setelah pull; push di-retry cycle depan."
    return 0
  fi
  if $COL_GIT push origin main >/dev/null 2>&1; then
    _col_log "pushed after pull."
  else
    _col_log "WARN: push still failed; will retry on next sync cycle."
  fi
  _col_lock_release
  return 0
}

# ---- periodic daemon ------------------------------------------------------
# Writes a pid file (+ the process start time, to detect pid reuse) so stop-all
# from ANOTHER shell can terminate it.
sync_daemon() {
  local interval="${COL_SYNC_PUSH_S:-${KH_SYNC_PUSH_S:-300}}"
  local pf="$COL_ROOT/logs/.pids/sync_daemon.pid"
  local pf_start="$COL_ROOT/logs/.pids/sync_daemon.pid.start"
  mkdir -p "$(dirname "$pf")"
  local oldpid
  oldpid=$(cat "$pf" 2>/dev/null || true)
  if [[ -n "$oldpid" ]] && kill -0 "$oldpid" 2>/dev/null; then
    # pid hidup, tapi mungkin REUSE dari proses lain: bandingkan waktu start
    # proses dengan yang tercatat saat daemon lama diluncurkan.
    if [[ -f "$pf_start" ]] && [[ "$(ps -p "$oldpid" -o lstart= 2>/dev/null)" != "$(cat "$pf_start" 2>/dev/null)" ]]; then
      _col_log "pid $oldpid ter-reuse (bukan daemon lama); pid file basi diabaikan."
    else
      _col_log "sync daemon already running (pid $oldpid)."
      return 0
    fi
  fi
  (
    trap '_col_lock_release; exit 0' TERM INT
    while :; do
      sleep "$interval" & SW=$!
      wait "$SW" 2>/dev/null || true   # interrupted instantly by TERM
      sync_pull
      sync_push
    done
  ) &
  COL_SYNC_DAEMON_PID=$!
  echo "$COL_SYNC_DAEMON_PID" > "$pf"
  ps -p "$COL_SYNC_DAEMON_PID" -o lstart= > "$pf_start" 2>/dev/null
  disown 2>/dev/null || true
  _col_log "sync daemon started (pid $COL_SYNC_DAEMON_PID, every ${interval}s)."
}

sync_daemon_stop() {
  local pf="$COL_ROOT/logs/.pids/sync_daemon.pid"
  local pf_start="$COL_ROOT/logs/.pids/sync_daemon.pid.start"
  local dpid
  dpid="$(cat "$pf" 2>/dev/null || true)"
  if [[ -n "$dpid" ]] && kill -0 "$dpid" 2>/dev/null; then
    kill -TERM "$dpid" 2>/dev/null
    _col_log "sync daemon stopped (pid $dpid)."
  fi
  rm -f "$pf" "$pf_start"
  # final flush on shutdown
  sync_push
}

# ---- CLI --------------------------------------------------------------------
# `bash runners/sync.sh <perintah>` — sync manual TANPA perlu start-all dulu.
# KRITIS utk fresh clone: sourcing file ini otomatis register driver union
# (blok atas), jadi pull manual pun bebas konflik marker di file progress.
# AI/mesin lain: INI cara sync yang benar — bukan `git pull` telanjang.
sync_main() {
  local cmd="${1:-status}"
  case "$cmd" in
    pull)        sync_pull ;;
    push)        sync_push ;;
    sync|both)   sync_pull && sync_push ;;
    agents)      _col_root_agents_refresh ;;
    daemon-stop) sync_daemon_stop ;;
    status)
      $COL_GIT fetch origin --quiet 2>/dev/null || true
      local div
      div="$($COL_GIT rev-list --left-right --count origin/main...HEAD 2>/dev/null || echo "?\t?")"
      _col_log "divergence (behind/ahead) = $(echo "$div" | tr '\t' '/')"
      $COL_GIT status --short | head -5
      ;;
    *)
      echo "pakai: bash runners/sync.sh [pull|push|sync|agents|status|daemon-stop]" >&2
      return 2
      ;;
  esac
}
# Eksekusi hanya saat DIJALANKAN langsung (bukan di-source oleh run_all_*.sh):
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  sync_main "$@"
  exit $?
fi
