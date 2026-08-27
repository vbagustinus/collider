#!/usr/bin/env bash
# build.sh — build metal-kangaroo for the CURRENT Mac.
# Safe to run repeatedly; idempotent. Must run on Apple Silicon (Metal only).
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
ARCH="$(uname -m)"
echo "== build metal-kangaroo on arch: $ARCH =="
if [[ "$ARCH" != "arm64" ]]; then
  echo "WARN: metal-kangaroo uses Apple Metal, which requires Apple Silicon (arm64)."
  echo "WARN: current arch '$ARCH' cannot build/run this collider."
  exit 3
fi
CC="${CC:-clang}"
if ! command -v "$CC" >/dev/null 2>&1; then
  echo "ERROR: clang not found. Install Xcode command line tools: xcode-select --install"
  exit 4
fi
echo "compiling main.m -> metal-kangaroo"
"$CC" -fobjc-arc -framework Foundation -framework Metal -O2 -Wall main.m -o metal-kangaroo
chmod +x metal-kangaroo
echo "OK: $(pwd)/metal-kangaroo"
file metal-kangaroo
