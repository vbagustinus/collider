#!/usr/bin/env bash
# setup.sh — one-shot init for the portable "collider" deployment on ANY Mac.
# Run after copying this folder to a new machine:
#     bash /path/to/collider/setup.sh
# It makes scripts executable, builds the Metal binary for the current arch,
# and runs a tiny sanity check (no GPU sweep).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

echo "=== collider setup : $HERE ==="
OS="$(uname -s)"; ARCH="$(uname -m)"
echo "host: $(uname -n) | $OS $ARCH"

if [[ "$OS" != "Darwin" ]]; then
  echo "ERROR: this collider targets macOS (Metal). Host OS is $OS."
  exit 3
fi
if [[ "$ARCH" != "arm64" ]]; then
  echo "ERROR: metal-kangaroo needs Apple Silicon (arm64). Host arch is $ARCH."
  exit 3
fi

echo "chmod +x runners / build"
chmod +x runners/*.sh tools/metal-kangaroo/build.sh 2>/dev/null || true

echo "--- building metal-kangaroo ---"
if bash tools/metal-kangaroo/build.sh; then
  echo "build OK"
else
  echo "build FAILED"; exit 4
fi

echo "--- verifying GPU device ---"
GPU_NAME="$(./tools/metal-kangaroo/metal-kangaroo --gpu-info 2>&1 | grep -i 'GPU device' | head -1)"
if [[ -n "$GPU_NAME" ]]; then
  echo "DETECTED: $GPU_NAME"
else
  echo "WARN: could not confirm GPU (Metal may be unavailable)."
fi

echo "--- sanity: --loop is inert; do a dry status instead ---"
bash runners/run_all_colliders.sh status | head -20

echo
echo "=== READY. Start the sweep with: ==="
echo "   bash $HERE/runners/run_all_colliders.sh start-all [seconds_per_round] [kangs]"
echo "   bash $HERE/runners/run_all_colliders.sh status"
echo "   bash $HERE/runners/run_all_colliders.sh stop-all"
echo
echo "Portable notes:"
echo " - metal-kangaroo is rebuilt per device (no committed binary)."
echo " - all paths are relative to this folder (copy anywhere, any macOS user)."
echo " - set COLLIDER_AUTOKANGS=1 to auto-size the kang pool to this Mac's RAM."
