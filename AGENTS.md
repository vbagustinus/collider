# AGENTS.md — collider kangaroo sweep Metal (repo multi-mesin)

Repo ini dijalankan oleh BEBERAPA KOMPUTER sekaligus dan disinkronkan lewat
GitHub. File ini adalah kesepakatan antar mesin: ikuti aturannya agar progress
saling melengkapi, tidak saling menginjak, dan tidak hilang.

## root_agents.md — konteks project utuh (WAJIB dibaca AI)
File `root_agents.md` di root folder repo ini adalah salinan dari AGENTS.md
induk yang ada di folder DI ATAS repo (`../AGENTS.md` — berisi konvensi
project keseluruhan: alamat target, hardware, etika, daftar semua tools).
Perintah untuk AI:
1. SEBELUM keputusan lintas-repo (hardware, alamat, prioritas, tools), baca
   `root_agents.md` di root folder repo ini — bukan cuma file ini.
2. JANGAN edit `root_agents.md` langsung. Single source of truth =
   `../AGENTS.md`. Snapshot ini OTOMATIS ter-refresh: tiap push di repo ini
   (fungsi sync.sh) dan tiap commit di project root (tools/sync_root_agents.sh
   + post-commit hook). Manual fallback: `cp ../AGENTS.md root_agents.md` lalu
   commit + push via sync helper.
3. Saat fresh clone di mesin baru, `root_agents.md` ikut ter-download otomatis
   (terlacak git) — AI langsung punya konteks penuh tanpa akses ke mesin lain.

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
   kode, config. Log runtime di-trim otomatis oleh `tools/trim_logs.sh`
   (dipanggil di start-all & stop-all; default: usia ≥3 hari → hapus,
   file >100 MB → potong tail 10 MB, total logs/ >300 MB → hapus tertua;
   whitelist `*.pct_history`/MATCH/FOUND/.pids tidak pernah disentuh).
   BARU 2026-09-22: script ini sebelumnya tidak ada (metal.log tumbuh
   ±1,4 MB/hari tanpa batas) — sekarang sudah ada dan terpasang di runner.
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
- Daemon sync tiap 60 MENIT (default `COL_SYNC_PUSH_S:-3600`, sejak 2026-09-22;
  sebelumnya 30 menit/`1800` sejak 2026-09-21): tarik progress mesin lain +
  cek MATCH tanpa spam commit. Tiap siklus bikin commit progress → 48
  siklus/hari menumpukkan `.git`; 60 menit memotongnya ~2×. Override via env
  (`COL_SYNC_PUSH_S=60`) bila perlu siklus cepat; MATCH relay tetap instan.
  Tanpa prompt kredensial (ssh BatchMode) — aktifkan ssh-agent SEBELUM
  start-all kalau ssh butuh passphrase.
- GIT GC (audit 2026-09-22): `gc.auto=256` diset lokal; `.git` pernah menumpuk
  6,23 MB loose object karena default 6700. Kalau `.git` membengkak, jalankan
  `git gc --aggressive --prune=now` (audit: 3,58 MiB pack + 6,23 MB loose →
  833 KiB, 309 commit utuh). JANGAN pernah rewrite/orphan history (Etika
  antar mesin).
- ANTI-ZONK MATCH: notifikasi hanya bunyi kalau log berisi 'SOLVED k = <hex>'
  (rc=0 saat timeout normal TIDAK dianggap match). `tools/sweep/sweep.py`
  verifikasi priv→pubkey→hash160 SEBELUM kirim dana (offline-safe) — MATCH
  palsu mustahil lolos sweep. FOUND file = hasil kerja semua mesin, ter-push via git.
- RELAY MATCH INSTAN (2026-09-21): saat MATCH → `sync.sh push` seketika + alert
  HP via ntfy.sh. Setup per mesin: install app "ntfy" di HP → subscribe satu
  topik rahasia yg SAMA antar mesin → `echo topik > tools/notify/NTFY_TOPIC`
  (di-gitignore, salin manual antar mesin). Tanpa file itu semua tetap jalan,
  hanya tanpa alert HP. Saat PULL: FOUND bertambah = mesin lain menang →
  alert lokal + HP otomatis.
- BACKUP LEDGER TEMUAN (2026-09-21): `KEYFOUNDKEYFOUND.txt` di root project =
  single source hasil temuan; di-mirror otomatis ke repo ini (ter-push) tiap
  siklus push (dedup + idempoten, merge=union anti-konflik antar mesin).
  JANGAN edit mirror manual — sumbernya root; jangan tambah baris duplikat.
- Kalau pull --rebase nyangkut saat ada commit "sync: ..." murni: abort →
  `reset --soft origin/main` → SATU commit fresh union semua → push.

## ATURAN SYNC UNTUK AI (WAJIB di SEMUA komputer)
AI yang bekerja di repo ini HARUS sinkron lewat helper repo, bukan git mentah.
`bash runners/sync.sh <cmd>` otomatis: register driver union (aman utk fresh
clone), lock anti-race, stash by-message, abort rebase tertinggal, tanpa
prompt kredensial.

| Situasi | Perintah wajib | JANGAN |
|---|---|---|
| Sebelum mulai kerja | `bash runners/sync.sh pull` | `git pull` telanjang |
| Selesai edit kode/config | commit → `bash runners/sync.sh push` | `git push` telanjang |
| Ragu soal state | `bash runners/sync.sh status` (harus 0/0) | `git reset --hard` |
| Sync dua arah cepat | `bash runners/sync.sh sync` | — |
| Fresh clone pertama kali | `bash runners/sync.sh sync` SEBELUM start-all | — |

Detail:
1. pull SEBELUM mulai + push SETELAH selesai. Jangan biarkan edit kode kotor
   berhari-hari — tree kotor non-progress memicu fallback merge (jalan, tapi
   menumpuk backlog).
2. File progress (`checkpoints/randomColliders*.js`, `logs/*.pct_history`,
   `FOUND_*`) TIDAK PERNAH di-resolve manual. Kalau kecap marker konflik
   (`<<<<<<<`): jangan pilih sisi — jalankan `bash runners/sync.sh sync`
   (union driver membersihkan marker saat merge berikutnya); kalau masih
   tersisa, hapus HANYA baris marker tanpa menyentuh baris data, lalu commit.
3. Konflik di file KODE (bukan progress): resolve manual biasa seperti repo
   git pada umumnya.
4. Error `pull skipped: tree masih kotor` berulang = ada file kode belum
   di-commit. Commit dulu — jangan stash paksa, jangan biarkan mengendap.
5. SETELAH `stop-all`: final flush sudah otomatis; verifikasi dengan
   `bash runners/sync.sh status` → harus `0/0`. Tidak perlu push manual lagi.
6. Daemon sync (start-all) menangani siklus biasa; CLI di atas untuk saat
   daemon mati, kerja manual, atau darurat.

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
