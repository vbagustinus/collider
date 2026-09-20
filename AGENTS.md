# AGENTS.md — collider kangaroo sweep Metal (repo multi-mesin)

Repo ini dijalankan oleh BEBERAPA KOMPUTER sekaligus dan disinkronkan lewat
GitHub. File ini adalah kesepakatan antar mesin: ikuti aturannya agar progress
saling melengkapi, tidak saling menginjak, dan tidak hilang.

## Tujuan project
- Sweep collider kangaroo (Metal GPU) untuk puzzle BTC p140/p145/p150/p155/p160
  via config `collider_jump_*_rnd.conf` (ENABLED=1). Master:
  `bash runners/run_all_colliders.sh start-all` / `stop-all` / `status`.
- Target: pubkey compressed dari `data/btc_hex_puzzle_1_sampai_160+0x.txt`
  (lihat repo root project). PUBKEY di config = 66-char kompres (02/03...) —
  JANGAN pernah "memperbaiki" ke 65-char; itu bug lama yang sudah dibenerin.
- Progress sekarang: kelima config ~99.8%+ via checkpoint kangaroo (lihat
  `status`). Angka = persentase checkpoint kangaroo, beda semantik dgn
  random-start keyhunt.

## Aturan wajib (semua komputer)
1. **start-all / stop-all hanya lewat master runner.** Sudah otomatis:
   sync pull+merge sebelum launch, commit+push saat stop, register driver
   union, idempotent (stop leftover dulu sebelum launch).
2. **LOG SINGLE-SOURCE di repo ini.** `logs/` + `checkpoints/` di SINI adalah
   satu-satunya tempat progress resmi (bukan di repo root b1000). Jangan bikin
   folder progress paralel.
3. **JANGAN edit checkpoint/pct_history manual.** `checkpoints/randomColliders*.js`
   + `logs/*.pct_history` di-merge driver union
   (`tools/merge_progress_union.py`, format `{presentage, hex}`) — dedup by
   hex/pct, anti konflik antar mesin.
4. **Config hanya boleh diubah sesuai kesepakatan:** `collider_jump_*_rnd.conf`
   boleh di-repair; `p*_kh.conf` dan `narrowed.conf` JANGAN disentuh tanpa
   instruksi eksplisit.
5. **JANGAN commit log mentah / binary.** Yang terlacak: progress, MATCH/FOUND,
   kode, config. Log runtime di-trim otomatis.
6. **Konflik merge progress?** Biarkan union driver bekerja; kalau ada marker
   `<<<<<<<` tersisa dari riwayat kotor, self-healing driver akan buang saat
   merge berikutnya. Jangan resolve manual dengan memilih satu sisi.
7. **Kredensial/secret jangan masuk repo.**

## Konvensi sync (runners/sync.sh, sudah diaudit 2026-09-20)
- Lock `.git/sync_push.lock` berisi pid owner; basi (owner mati / >600s)
  dihapus otomatis. sync_pull & sync_push share lock yang sama.
- Pop stash by-message (`sync: auto-stash*`) — user stash tidak tersentuh.
- Rebase/merge tertinggal di-abort otomatis di awal/akhir sync_pull.
- Push dibedakan: offline/auth vs non-FF; fallback merge --autostash saat tree
  kotor non-progress (file kode belum di-commit — commit dulu!).
- Daemon sync tiap 300s, tanpa prompt kredensial (ssh BatchMode). Kalau ssh-mu
  butuh passphrase, aktifkan ssh-agent SEBELUM start-all.
- Kalau pull --rebase nyangkut saat ada commit "sync: ..." murni: abort →
  `reset --soft origin/main` → SATU commit fresh union semua → push.

## Batas hardware (default MacBook M2 16GB — sesuaikan di mesin lain)
- 1 GPU process untuk sweep Metal (jangan dobel master di mesin yang sama).
- Mesin RAM 16GB: jangan jalankan keyhunt CPU 7-worker + collider Metal
  full-load bersamaan tanpa memantau RAM.
- prefer foreground Metal run saat eksperimen; daemonized hanya utk sweep.

## Etika antar mesin
- Jangan reset/rewrite history yang sudah ter-push (progress mesin lain ada
  di sana).
- Eksperimen besar (config baru, rotasi berbeda) tulis niatnya di commit
  message — mesin lain membaca git, bukan chat.
- MATCH/FOUND file = hasil kerja semua mesin; jangan pernah dihapus/di-ignore.
