# collider — portable BTC puzzle kangaroo (Metal GPU)

Collider sweep untuk BTC puzzle (metode kangaroo / pollard) yang berjalan **100% di GPU
Apple Metal**. Folder ini self-contained dan dirancang supaya bisa di-copy/clone ke Mac
mana pun (termasuk Mac M4 16 GB+) tanpa Path atau binary yang terikat device.

## Apa yang ada
- `runners/run_all_colliders.sh` — master controller: sweep semua config
  `configs/collider_jump_*_rnd.conf` yang `ENABLED=1`, 1 GPU process sekaligus.
- `runners/run_collider_jump.sh` — per-config runner (random subrange per round,
  checkpoint otomatis di `checkpoints/randomColliders<PZ>.js`).
- `configs/collider_jump_p*_rnd.conf` — target puzzle (p140/145/150/155/160 aktif, p30 off).
- `tools/metal-kangaroo/` — source `main.m` + `kangaroo.metal` + `Makefile` + `build.sh`.
  **Binary tidak di-commit**; di-compile otomatis di device tujuan.
- `checkpoints/` — progress tiap puzzle (ikut terbawa, lanjut dari mana tahap terakhir).
- `setup.sh` — inisialisasi satu kali di Mac baru.

## Persyaratan
- macOS + Apple Silicon (arm64). Metal hanya ada di Apple Silicon.
- Xcode command line tools: `xcode-select --install` (untuk `clang`).
- Tidak ada path hard-coded; semua relatif terhadap folder ini.

## Setup di Mac baru (mis. M4 16 GB)
```bash
bash /path/ke/collider/setup.sh
```
Script akan: chmod runner, compile `metal-kangaroo` untuk arch ini, dan verifikasi
GPU device terdeteksi (cetak nama GPU, mis. "Apple M4").

## Menjalankan
```bash
bash runners/run_all_colliders.sh start-all [detik_per_round] [kangs]
bash runners/run_all_colliders.sh status
bash runners/run_all_colliders.sh stop-all
```
Contoh: `start-all 600` → tiap config diskak 600 detik lalu lanjut ke config berikutnya,
berputar terus sampai ketemu MATCH atau `stop-all`.

## Pastikan benar-benar pakai GPU
- Binary pakai `MTLCreateSystemDefaultDevice()` + compute kernel `kangaroo.metal`,
  jadi walk terjadi di GPU, bukan CPU.
- Saat start, baris `GPU device: <nama GPU>` muncul di log (lihat
  `logs/<puzzle>.metal.log`) — itu konfirmasi GPU aktif.
- Cek cepat tanpa sweep: `tools/metal-kangaroo/metal-kangaroo --gpu-info`.

## Device-aware (M4 16 GB+)
- Pool kangaroo (`KANGS`) otomatis menyesuaikan RAM: di 16 GB -> 16384 (4× lipat
  dari nilai config 4096). RAM lebih besar -> pool lebih besar lagi.
  Pakai config asli: `COLLIDER_FIXEDKANGS=1 bash runners/run_all_colliders.sh start-all`.
- Kalau GPU beda (mis. M4 Pro/Max dengan lebih banyak core), naikkan manual via arg
  ke-3: `start-all 600 32768`.

## Auto-sweep BTC saat MATCH
Saat `metal-kangaroo` mencetak `SOLVED k = <priv>`, runner otomatis:
1. parse private key dari log,
2. panggil `tools/sweep/sweep.py` yang:
   - derivasi address dari `PUBKEY` config (P2PKH),
   - cek `TARGET_HASH160` cocok,
   - fetch UTXO via blockstream/esplora,
   - bangun + tanda-tangani tx P2PKH mengirim saldo penuh (minus fee) ke alamat tujuan,
   - broadcast.
3. catat `tools/sweep/sweep_done.log` (tanpa priv key) agar tidak dobel sweep.

Alamat tujuan (kemana kirim):
- default: `1PqYBqJAsT6AVCAr6ueuTYuRUu61NHet5` (BTC puzzle-solve sweep addr, AGENTS.md).
- override: file `tools/sweep/SWEEP_ADDRESS`, atau env `SWEEP_ADDRESS=...`.
- tes tanpa broadcast: `SWEEP_DRYRUN=1` (cetak raw tx, tidak di-broadcast).

Validasi sudah dilakukan: derivasi address cocok dengan vektor known (priv `d2c55`
-> `1HsMJxNiV7TLxmoF6uJNkydxPFDog4NQum`), dan tiap signature self-verify lolos.
Pastikan Mac target punya akses internet (HTTPS ke blockstream.info) untuk fetch/broadcast.

### Jaminan MATCH valid & sweep working
- **MATCH valid dijamin**: sebelum mengirim saldo, `sweep.py` memverifikasi
  `priv -> PUBKEY -> TARGET_HASH160` persis sama dengan config. Kalau tidak cocok,
  sweep **di-batalkan** (tidak ada dana yang terkirim ke key salah).
  Bukti: dry-run dengan priv `d2c55` mencetak `MATCH VALID: priv -> PUBKEY ->
  TARGET_HASH160 verified OK`.
- **Sweep working dijamin**: serialisasi tx + tanda tangan sudah diuji live ke
  node blockstream **testnet** (`--testnet`). Tx diterima & di-decode node
  (HTTP 400 `bad-txns-inputs-missingorspent` = hanya ditolak karena input dummy
  tak ada dana, bukan karena format/signature salah). Artinya path broadcast
  (`POST /tx`) dan format wire tx benar.
- Tes sendiri kapan saja tanpa risiko dana:
  `python3 tools/sweep/sweep.py --config <conf> --priv <hex> --dry-run`
  `python3 tools/sweep/sweep.py --config <conf> --priv <hex> --testnet`  (bukti live ke testnet)

## Catatan portabilitas
- Pindah antar Mac: cukup copy folder ini. `setup.sh` akan rebuild binary bila arch
  berubah; path relatif jadi tidak masalah username/folder.
- `pgrep/pkill` di-scope ke `collider/...` supaya `stop-all` tidak membunuh collider
  lain (mis. `b1000`) yang kebetulan jalan di Mac yang sama.
- Saran: tambahkan `tools/metal-kangaroo/metal-kangaroo` ke `.gitignore` agar binary
  hasil compile device tertentu tidak ke-commit.
