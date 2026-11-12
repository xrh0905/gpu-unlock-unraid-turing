#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Build the pinned NVIDIA 610.43.03 firmware as a Slackware .txz for Unraid.
#
#   build-firmware.sh [outdir] [workdir]
#
# Downloads the two NVIDIA inputs pinned in artifacts-610.43.03.json (SHA-256
# checked), generates the six TU102 firmware files with nlzy/turing-unlock's
# generators, and packs them for /lib/firmware/turing-unlock/610.43.03/.
#
# Nothing is redistributed: the inputs come from NVIDIA and the Arch Linux Archive, and the
# output stays on the machine that runs this script.
#
# Needs: python3 >= 3.9, zstd, tar, xz, sha256sum. ~1 GiB free in workdir.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HERE/../out/firmware}
WORK=${2:-${TMPDIR:-/tmp}/turing-unlock-firmware.$$}
NV=610.43.03
SRC=NVIDIA-kernel-module-source-$NV
UTILS=nvidia-utils-$NV-1-x86_64.pkg.tar.zst
FW_FILES=(booter_load_tu102.bin gsp_tu10x.bin gsp_boot_tu102.bin gsp_boot_desc_tu102.bin sec2_bl_tu102.bin v67-tu102-$NV.bin)
PKG=turing-unlock-firmware-$NV-noarch-1.txz

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo; echo "==> $*"; }

for c in python3 zstd tar xz sha256sum; do
  command -v "$c" >/dev/null 2>&1 || die "missing $c"
done
mkdir -p "$OUT" "$WORK/inputs" "$WORK/src" "$WORK/assets"

log "Downloading and checking the pinned NVIDIA $NV inputs"
python3 -I "$HERE/fetch_artifacts.py" "$WORK/inputs"

log "Generating the TU102 firmware assets"
rm -rf "$WORK/src" "$WORK/assets"
mkdir -p "$WORK/src" "$WORK/assets"
tar -xf "$WORK/inputs/$SRC.tar.xz" -C "$WORK/src"
[ -d "$WORK/src/$SRC" ] || die "$SRC.tar.xz did not unpack to $WORK/src/$SRC"
python3 -I "$HERE/generate_v67.py" "$WORK/inputs/$UTILS" "$WORK/assets"
python3 -I "$HERE/extract_boot_assets.py" "$WORK/src/$SRC" "$WORK/assets"

for f in "${FW_FILES[@]}"; do
  [ -s "$WORK/assets/$f" ] || die "generator did not produce $f"
done
[ -s "$WORK/assets/NVIDIA-LICENSE" ] || die "generator did not produce NVIDIA-LICENSE"

log "Packing $PKG"
P="$WORK/pkg"
rm -rf "$P"
mkdir -p "$P/install" "$P/lib/firmware/turing-unlock/$NV" "$P/usr/share/licenses/turing-unlock-firmware"
for f in "${FW_FILES[@]}"; do
  install -m644 "$WORK/assets/$f" "$P/lib/firmware/turing-unlock/$NV/$f"
done
install -m644 "$WORK/assets/NVIDIA-LICENSE" "$P/usr/share/licenses/turing-unlock-firmware/NVIDIA-LICENSE"
install -m644 "$HERE/NOTICE.md" "$P/usr/share/licenses/turing-unlock-firmware/NOTICE.md"
slack_desc() {
  local n=$1; shift
  printf '%*s|-----handy-ruler------------------------------------------------------|\n' ${#n} ''
  local i=0
  for l in "$@"; do printf '%s: %s\n' "$n" "$l"; i=$((i + 1)); done
  while [ $i -lt 11 ]; do printf '%s:\n' "$n"; i=$((i + 1)); done
}
slack_desc turing-unlock-firmware "turing-unlock-firmware (pinned NVIDIA $NV firmware for turing_unlock)" "" \
  "Generated from the pinned NVIDIA $NV inputs by nlzy/turing-unlock's" \
  "firmware scripts; every input and output is SHA-256 checked." \
  "Installed to /lib/firmware/turing-unlock/$NV/." \
  "NVIDIA firmware stays under NVIDIA's terms; see NOTICE.md." \
  "" "Source: https://github.com/nlzy/turing-unlock" > "$P/install/slack-desc"

( cd "$P" && tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@${SOURCE_DATE_EPOCH:-$(date +%s)}" \
    -cJf "$OUT/$PKG" install lib usr )
( cd "$OUT" && sha256sum "$PKG" > "$PKG.sha256" )
rm -rf "$WORK/src" "$WORK/assets" "$WORK/pkg"
ls -l "$OUT/$PKG"
