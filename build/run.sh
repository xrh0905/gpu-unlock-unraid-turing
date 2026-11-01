#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Build on any Linux host with Docker. Passes the same knobs as build.sh:
#   UNRAID_VERSION=7.3.2 ./build/run.sh
#   KERNEL_CONFIG=/path/6.18.38-Unraid.config ./build/run.sh
#   UNRAID_SRC=/usr/src ./build/run.sh          (on the Unraid box itself)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
OUT=${OUT:-$REPO/out}
CACHE=${CACHE:-$REPO/cache}
BASE_IMAGE=${BASE_IMAGE:-gcc:15}
mkdir -p "$OUT" "$CACHE"

docker build -f "$HERE/Dockerfile" --build-arg BASE_IMAGE="$BASE_IMAGE" -t turing-unlock-build "$REPO"

args=(--rm -v "$OUT:/out" -v "$CACHE:/cache" -e OUT=/out -e CACHE=/cache)
for v in UNRAID_VERSION KERNEL_RELEASE TURING_UNLOCK_REF TURING_UNLOCK_REPO BUILD_FIRMWARE JOBS KERNEL_MIRROR; do
  [ -n "${!v:-}" ] && args+=(-e "$v")
done
if [ -n "${KERNEL_CONFIG:-}" ]; then
  [ -f "$KERNEL_CONFIG" ] || { echo "KERNEL_CONFIG=$KERNEL_CONFIG not found" >&2; exit 1; }
  args+=(-v "$(realpath "$KERNEL_CONFIG"):/kernel-config:ro" -e KERNEL_CONFIG=/kernel-config)
fi
if [ -n "${TURING_UNLOCK_SRC:-}" ]; then
  args+=(-v "$(realpath "$TURING_UNLOCK_SRC"):/turing-unlock-src:ro" -e TURING_UNLOCK_SRC=/turing-unlock-src)
fi
if [ -z "${UNRAID_SRC:-}" ] && ls -d /usr/src/linux-*-Unraid >/dev/null 2>&1; then
  UNRAID_SRC=/usr/src
fi
if [ -n "${UNRAID_SRC:-}" ]; then
  args+=(-v "$(realpath "$UNRAID_SRC"):/unraid-src:ro" -e UNRAID_SRC=/unraid-src)
fi

docker run "${args[@]}" turing-unlock-build
