#!/bin/bash
# notify_match.sh — alert MATCH ke HP via ntfy.sh (tanpa server, cukup curl).
#
# Setup SEKALI per mesin:
#   1. Install app "ntfy" di HP (iOS/Android), subscribe ke satu topik rahasia
#      yang SAMA di semua komputermu, mis. "btc-match-<string-acak-panjang>".
#   2. echo "topik-rahasia-mu" > tools/notify/NTFY_TOPIC   (file ini DI-GITIGNORE
#      supaya topik tidak bocor lewat repo publik; salin manual antar mesinmu).
#   3. Tes: curl -d "tes dari mac" ntfy.sh/<topik-mu>
#
# Tanpa file config = no-op aman (hanya log lokal). Override via env NFY_TOPIC.
#
# Pakai: bash tools/notify_match.sh "JUDUL" "isi pesan"
set -u
D="$(cd "$(dirname "$0")/.." && pwd)"
TITLE="${1:-MATCH}"
BODY="${2:-}"
TOPIC="${NTFY_TOPIC:-}"
TF="$D/tools/notify/NTFY_TOPIC"
if [[ -z "$TOPIC" && -f "$TF" ]]; then
  TOPIC="$(head -1 "$TF" | tr -d ' \r\n')"
fi
if [[ -z "$TOPIC" ]]; then
  echo "[notify] (alert HP belum diset: tools/notify/NTFY_TOPIC) $TITLE | $BODY"
  exit 0
fi
if curl -s -m 10 -H "Title: $TITLE" -H "Priority: high" -H "Tags: rotating_light" \
     -d "$BODY" "ntfy.sh/$TOPIC" >/dev/null 2>&1; then
  echo "[notify] alert HP terkirim (ntfy/$TOPIC)."
else
  echo "[notify] WARN: kirim ntfy gagal (offline?) — $TITLE"
fi
