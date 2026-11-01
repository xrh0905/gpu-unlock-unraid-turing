#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Build nlzy/turing-unlock for one Unraid kernel and pack it as a Slackware package.
#
# Produces, under $OUT:
#   <kernel>/turing-unlock-module-<ver>-<kernel>-1.txz  turing_unlock.ko built for exactly that kernel
#   firmware/turing-unlock-firmware-<nv>-noarch-1.txz   six pinned 610.43.03 firmware files (kernel independent)
# plus a .sha256 next to each. The Unraid plugin installs the module at rc.modules (or from its own
# start step) and loads it before the nvidia driver binds the card.
#
# Which Unraid kernel to build for (first one that applies):
#   KERNEL_CONFIG=/path/to/config           a copy of /usr/src/linux-<ver>-Unraid/config from the box
#   /unraid-src exists                      the box's /usr/src bind-mounted in (run.sh does this)
#   UNRAID_VERSION=7.3.2                    downloads that release and reads the config out of it
#
# Other knobs: TURING_UNLOCK_REPO / TURING_UNLOCK_REF (pinned commit by default),
#              TURING_UNLOCK_SRC (an existing checkout; skips the clone),
#              BUILD_FIRMWARE=auto|yes|no, KERNEL_RELEASE, JOBS, OUT, CACHE,
#              KERNEL_MIRROR, KERNEL_TARBALL.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
OUT=${OUT:-/out}
CACHE=${CACHE:-/cache}
JOBS=${JOBS:-$(nproc)}
TURING_UNLOCK_REPO=${TURING_UNLOCK_REPO:-https://github.com/nlzy/turing-unlock}
# v2.0.0, main as of 2026-10-26.
TURING_UNLOCK_REF=${TURING_UNLOCK_REF:-417f333263ff169e8f449c931b70db9dfd7b8ef4}
TURING_UNLOCK_SRC=${TURING_UNLOCK_SRC:-}
BUILD_FIRMWARE=${BUILD_FIRMWARE:-auto}
KERNEL_MIRROR=${KERNEL_MIRROR:-https://cdn.kernel.org/pub/linux/kernel}
UNRAID_SRC=${UNRAID_SRC:-/unraid-src}

log() { echo; echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

modinfo_field() {
  if command -v modinfo >/dev/null 2>&1; then modinfo -F "$1" "$2"; else strings -n 4 "$2" | sed -n "s/^$1=//p"; fi
}
slack_desc() {
  local n=$1; shift
  printf '%*s|-----handy-ruler------------------------------------------------------|\n' ${#n} ''
  local i=0
  for l in "$@"; do printf '%s: %s\n' "$n" "$l"; i=$((i + 1)); done
  while [ $i -lt 11 ]; do printf '%s:\n' "$n"; i=$((i + 1)); done
}
pack() { # pack <root> <file.txz>
  local root=$1 outfile=$2
  ( cd "$root" && tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@${SOURCE_DATE_EPOCH:-$(date +%s)}" \
      -cJf "$outfile" install $(ls -d -- * | grep -vx install) )
  ( cd "$(dirname "$outfile")" && sha256sum "$(basename "$outfile")" > "$outfile.sha256" )
  ls -l "$outfile"
}

mkdir -p "$OUT" "$CACHE"/{configs,kernel,inputs}

# ---------------------------------------------------------------------------------------------
log "Kernel config"
if [ -n "${KERNEL_CONFIG:-}" ]; then
  [ -f "$KERNEL_CONFIG" ] || die "KERNEL_CONFIG=$KERNEL_CONFIG not found"
  d=$(basename "$(cd "$(dirname "$KERNEL_CONFIG")" && pwd)")
  case "$d" in
    linux-*-Unraid) KR=${d#linux-} ;;
    *) KR=$(sed -n 's/^# Linux\/x86 \([0-9.]*\).*Kernel Configuration/\1/p' "$KERNEL_CONFIG")$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"/\1/p' "$KERNEL_CONFIG") ;;
  esac
  [ -n "${KERNEL_RELEASE:-}" ] && KR=$KERNEL_RELEASE
  [ -n "$KR" ] || die "cannot name the kernel from $KERNEL_CONFIG; set KERNEL_RELEASE=6.18.38-Unraid"
  cp "$KERNEL_CONFIG" "$CACHE/configs/$KR.config"
elif [ -d "$UNRAID_SRC" ] && ls -d "$UNRAID_SRC"/linux-*-Unraid >/dev/null 2>&1; then
  KR=$(KERNEL_RELEASE="${KERNEL_RELEASE:-$(uname -r)}" "$HERE/unraid-kernel-config.sh" "$UNRAID_SRC" "$CACHE/configs")
elif [ -n "${UNRAID_VERSION:-}" ]; then
  KR=$("$HERE/unraid-kernel-config.sh" "$UNRAID_VERSION" "$CACHE/configs")
else
  die "tell me which kernel: UNRAID_VERSION=7.3.2, KERNEL_CONFIG=/path/config, or mount the box's /usr/src at /unraid-src"
fi
CFG="$CACHE/configs/$KR.config"
[ -f "$CFG" ] || die "config $CFG missing"
KVER=$(sed -n 's/^# Linux\/x86 \([0-9.]*\).*Kernel Configuration/\1/p' "$CFG")
[ -n "$KVER" ] || die "cannot read the upstream kernel version from $CFG"
echo "kernel release: $KR   upstream: $KVER   config: $CFG"
grep -q '^CONFIG_MODVERSIONS=y' "$CFG" && die "this kernel uses CONFIG_MODVERSIONS; a full kernel build would be needed (Unraid normally does not)"
grep -q '^CONFIG_MODULE_SIG_FORCE=y' "$CFG" && die "this kernel enforces module signatures"
echo "compiler the kernel was built with: $(sed -n 's/^CONFIG_CC_VERSION_TEXT="\(.*\)"/\1/p' "$CFG")   (here: $(gcc --version | head -1))"

# ---------------------------------------------------------------------------------------------
log "Kernel source $KVER"
KDIR="$CACHE/kernel/$KR/linux-$KVER"
TARBALL=${KERNEL_TARBALL:-$CACHE/kernel/linux-$KVER.tar.xz}
if [ ! -f "$TARBALL" ]; then
  major=${KVER%%.*}
  url="$KERNEL_MIRROR/v$major.x/linux-$KVER.tar.xz"
  echo "downloading $url"
  curl -fL --retry 3 -o "$TARBALL.part" "$url" && mv "$TARBALL.part" "$TARBALL"
  if sums=$(curl -fsSL --retry 2 "$KERNEL_MIRROR/v$major.x/sha256sums.asc" 2>/dev/null); then
    want=$(echo "$sums" | grep " linux-$KVER.tar.xz$" | cut -d' ' -f1 || true)
    have=$(sha256sum "$TARBALL" | cut -d' ' -f1)
    if [ -n "$want" ] && [ "$want" != "$have" ]; then rm -f "$TARBALL"; die "linux-$KVER.tar.xz checksum mismatch"; fi
    [ -n "$want" ] && echo "sha256 ok"
  fi
fi
if [ ! -f "$KDIR/.prepared" ]; then
  rm -rf "$KDIR"; mkdir -p "$(dirname "$KDIR")"
  tar -xf "$TARBALL" -C "$(dirname "$KDIR")"
  [ -d "$KDIR" ] || die "tarball did not unpack to $KDIR"
  cp "$CFG" "$KDIR/.config"
  make -C "$KDIR" olddefconfig >/dev/null
  make -C "$KDIR" -j"$JOBS" modules_prepare >/dev/null
  got=$(make -C "$KDIR" -s kernelrelease)
  [ "$got" = "$KR" ] || die "prepared tree reports kernelrelease '$got', expected '$KR'"
  touch "$KDIR/.prepared"
fi
echo "prepared: $KDIR ($(make -C "$KDIR" -s kernelrelease))"

# ---------------------------------------------------------------------------------------------
log "turing-unlock source @ $TURING_UNLOCK_REF"
if [ -n "$TURING_UNLOCK_SRC" ]; then
  SRC=$TURING_UNLOCK_SRC
  [ -d "$SRC/kernel/turing_unlock" ] || die "TURING_UNLOCK_SRC=$SRC does not contain kernel/turing_unlock"
else
  SRC="$CACHE/turing-unlock"
  if [ ! -d "$SRC/.git" ]; then
    git clone -q "$TURING_UNLOCK_REPO" "$SRC"
  fi
  git -c safe.directory="*" -C "$SRC" fetch -q origin "$TURING_UNLOCK_REF" 2>/dev/null || git -c safe.directory="*" -C "$SRC" fetch -q origin
  git -c safe.directory="*" -C "$SRC" -c advice.detachedHead=false checkout -q --detach "$TURING_UNLOCK_REF" 2>/dev/null \
    || git -c safe.directory="*" -C "$SRC" -c advice.detachedHead=false checkout -q --detach "origin/$TURING_UNLOCK_REF"
fi
COMMIT=$(git -c safe.directory="*" -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)
VERSION=$(cat "$SRC/VERSION")
NV=$(sed -n 's/^NV *:= *//p' "$SRC/Makefile")
[ -n "$NV" ] || die "cannot read the pinned NVIDIA version from the Makefile"
echo "turing-unlock $VERSION (commit ${COMMIT:0:12}), pinned NVIDIA inputs $NV"

# ---------------------------------------------------------------------------------------------
log "Building turing_unlock.ko for $KR"
WORK="$CACHE/work/$KR"
rm -rf "$WORK"; mkdir -p "$WORK"
cp -r "$SRC/kernel/turing_unlock" "$WORK/mod"
# Without a full kernel build there is no Module.symvers, so modpost cannot check exports and
# only warns; the symbols resolve at insmod time. Check each one against the kernel source below.
make -C "$WORK/mod" KDIR="$KDIR" KBUILD_MODPOST_WARN=1 -j"$JOBS" 2>&1 \
  | grep -vE "undefined!|Module.symvers is missing|Modules may not have|unresolved symbol|KBUILD_MODPOST_WARN|at your own risk|suppressed .* unresolved" || true
KO="$WORK/mod/turing_unlock.ko"
[ -f "$KO" ] || die "build failed: no turing_unlock.ko"
VERMAGIC=$(modinfo_field vermagic "$KO")
[ "${VERMAGIC%% *}" = "$KR" ] || die "vermagic '$VERMAGIC' does not match $KR"
echo "vermagic: $VERMAGIC"

missing=0
for s in $(nm -u "$KO" | awk '{print $2}' | sed 's/^__pfx_//' | sort -u); do
  case "$s" in
    __fentry__|__stack_chk_fail|_printk|__x86_return_thunk|__x86_indirect_thunk*|__SCT__*|__ubsan*|__kcfi*|__cfi_*|__fortify_panic|__this_module|__start_*|__stop_*|__sanitizer*|__tsan*|__asan*|__kasan*|__gcov*|__ref*|__kcsan*|__init*|init_module|cleanup_module) continue ;;
  esac
  if ! grep -rqE "EXPORT_SYMBOL(_GPL|_NS|_NS_GPL)?\($s(\)|,)|define_dev_printk_level\($s," \
       "$KDIR/kernel" "$KDIR/drivers/pci" "$KDIR/drivers/base" "$KDIR/lib" "$KDIR/arch/x86" "$KDIR/mm" \
       "$KDIR/drivers/firmware" "$KDIR/drivers/video" 2>/dev/null; then
    echo "WARNING: symbol $s not found as an export in the kernel source"; missing=$((missing + 1))
  fi
done
[ "$missing" -eq 0 ] && echo "all unresolved symbols are kernel exports" || echo "WARNING: $missing symbol(s) could not be verified; the module may fail to load"

# ---------------------------------------------------------------------------------------------
log "Packing turing-unlock-module-$VERSION-$KR-1.txz"
P="$WORK/pkg-module"
rm -rf "$P"
mkdir -p "$P/install" "$P/lib/modules/$KR/extra" "$P/etc/rc.d" \
         "$P/usr/share/doc/turing-unlock-$VERSION" "$P/usr/share/licenses/turing-unlock"
install -m644 "$KO" "$P/lib/modules/$KR/extra/turing_unlock.ko"
install -m755 "$HERE/rc.modules.turing-unlock" "$P/etc/rc.d/rc.modules-$KR"
install -m644 "$SRC/README.md" "$P/usr/share/doc/turing-unlock-$VERSION/README.md"
install -m644 "$SRC/licenses/GPL-2.0.txt" "$P/usr/share/licenses/turing-unlock/GPL-2.0.txt"
cat > "$P/usr/share/doc/turing-unlock-$VERSION/BUILD-INFO" <<EOF
turing-unlock $VERSION
source    $TURING_UNLOCK_REPO @ $COMMIT
kernel    $KR (linux-$KVER + Unraid config)
vermagic  $VERMAGIC
built     $(date -u +%Y-%m-%dT%H:%M:%SZ) with $(gcc --version | head -1)
firmware  turing-unlock/$NV/ (separate package turing-unlock-firmware-$NV)
EOF
slack_desc turing-unlock-module "turing-unlock-module (TU102 FP16 tensor-core unlock)" "" \
  "turing_unlock.ko by nlzy, built for Unraid kernel $KR." \
  "Unlocks the full-speed FP16 tensor cores of NVIDIA TU102 cards" \
  "(e.g. RTX 2080 Ti 10de:1e07) before the nvidia driver binds them." \
  "Needs turing-unlock-firmware-$NV. Load with targets=all or PCI addresses." \
  "" "Source: $TURING_UNLOCK_REPO" "Commit: ${COMMIT:0:12}" > "$P/install/slack-desc"
mkdir -p "$OUT/$KR"
pack "$P" "$OUT/$KR/turing-unlock-module-$VERSION-$KR-1.txz"
cp "$P/usr/share/doc/turing-unlock-$VERSION/BUILD-INFO" "$OUT/$KR/BUILD-INFO"

# ---------------------------------------------------------------------------------------------
FWPKG="$OUT/firmware/turing-unlock-firmware-$NV-noarch-1.txz"
if [ "$BUILD_FIRMWARE" = yes ] || { [ "$BUILD_FIRMWARE" = auto ] && [ ! -f "$FWPKG" ]; }; then
  log "Building the pinned $NV firmware package (downloads NVIDIA inputs; SHA-256 checked)"
  "$REPO/firmware/build-firmware.sh" "$OUT/firmware" "$CACHE/firmware-work"
elif [ -f "$FWPKG" ]; then
  log "Firmware package: keeping existing $FWPKG (kernel independent)"
else
  log "Firmware package: skipped (BUILD_FIRMWARE=$BUILD_FIRMWARE); the plugin needs one, run with BUILD_FIRMWARE=yes"
fi

# ---------------------------------------------------------------------------------------------
log "Done"
cat <<EOF
  module  : $OUT/$KR/turing-unlock-module-$VERSION-$KR-1.txz
  firmware: $FWPKG$([ -f "$FWPKG" ] || echo '   (MISSING)')
Copy them to the Unraid flash:
  /boot/config/plugins/gpu-turing-unlock/packages/${KR%%-*}/        <- module .txz + .sha256
  /boot/config/plugins/gpu-turing-unlock/packages/firmware/         <- firmware .txz + .sha256
EOF
