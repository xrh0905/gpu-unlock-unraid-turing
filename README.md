# Turing Unlock for Unraid

Unraid plugin for [nlzy/turing-unlock](https://github.com/nlzy/turing-unlock): a Linux kernel module
that unlocks the full-speed FP16 tensor cores of NVIDIA Turing GPUs, primarily the TU102
**RTX 2080 Ti** (`10de:1e07`, including 22 GB modded cards). Dense FP16 GEMM (LLM prefill,
diffusion) gets faster; memory-bound work (LLM decode) does not.

The module has to run **before** the nvidia driver binds the card. This plugin installs it from
`/etc/rc.d/rc.modules-<kernel>` (Unraid's early third-party-driver hook) and, as a fallback, from
its own plugin install step — both before `nvidia-driver.plg` runs `modprobe nvidia`.

> **This is unofficial and risky.** The unlock writes volatile GPU firmware state. Tensor cores at
> full speed draw more power; a 22 GB modded card is outside NVIDIA's specifications. A failed run
> can leave the card in a bad state until a full power-off. Read the upstream README and its issue
> reports before using it. Not affiliated with nlzy, Lime Technology or NVIDIA.

## Install

1. In Unraid: **Plugins → Install Plugin** and paste
   ```
   https://github.com/xrh0905/gpu-unlock-unraid-turing/releases/latest/download/gpu-turing-unlock.plg
   ```
2. Open **Settings → User Utilities → Turing Unlock**.
3. Set **Cards to unlock** to the BDF of the host card, e.g. `0000:3b:00.0` (`lspci -D | grep -i nvidia`).
   `all` also works, but a card passed through to a VM is bound to `vfio-pci` and is skipped — and a
   VM's FLR would clear the unlock anyway.
4. The release also carries the pinned firmware package; the plugin downloads it with the module.
   If it is missing (or you want to rebuild it yourself), click **Rebuild firmware package**.
5. Reboot. Check `dmesg | grep turing_unlock`: a good run ends with
   `TU102 FEAT UNLOCKED` and `pci 0000:3b:00.0: turing_unlock: unlocked`. The status page on the
   settings page shows the same.

The first boot after installing downloads the module package for your exact kernel from the
release. Packages for kernels not in the release are skipped; the plugin sends a notification and
leaves the card at the stock rate.

### Firmware

The release carries `turing-unlock-firmware-610.43.03-noarch-1.txz`, generated in CI from the exact
inputs upstream pins, with every input and output checked against its SHA-256. `gsp_tu10x.bin` and
the other five files are unchanged NVIDIA firmware and stay under NVIDIA's terms; the package
contains `NOTICE.md` and the NVIDIA Driver License Agreement. Upstream's
[`firmware/NOTICE.md`](firmware/NOTICE.md) notes that redistribution approval is not claimed — if
that matters for your distribution, delete the firmware asset from the release and use the plugin's
local **Rebuild firmware package** action, which downloads from NVIDIA/CachyOS on the server.

### RTD3

The unlock is volatile. An idle D3cold transition clears it. The plugin writes
`options nvidia NVreg_DynamicPowerManagement=0x00` to `/etc/modprobe.d/zz-turing-unlock.conf` and
`/boot/config/modprobe.d/zz-turing-unlock.conf`, disabling RTD3 for every NVIDIA GPU in the server.
Removing the plugin removes those files.

## What the release contains

For each Unraid version in the workflow matrix (default `7.3.2`, `7.3.3`, `7.3.4`):

| Asset | Contents |
|---|---|
| `turing-unlock-module-2.0.0-<kernel>-1.txz` | `turing_unlock.ko` in `/lib/modules/<kernel>/extra/`, plus `/etc/rc.d/rc.modules-<kernel>` |
| `turing-unlock-firmware-610.43.03-noarch-1.txz` | Six pinned NVIDIA 610.43.03 files in `/lib/firmware/turing-unlock/610.43.03/` |
| `*.txz.sha256` | Checksum used by `rc.modules` and the plugin |
| `gpu-turing-unlock.plg` | Plugin definition; downloads the matching module and firmware packages and embeds the firmware builder |
| `SHA256SUMS` | Checksums for the release assets |

Unraid versions in the default matrix: 7.3.2 → kernel 6.18.38, 7.3.3 → 6.18.54, 7.3.4 → 6.18.58.
A kernel without a package is safe: nothing loads and the plugin notifies.

## Build locally

Any Linux host with Docker (if Docker is root-only, run `sudo ./build/run.sh` or add your user to the
`docker` group):

```bash
# for the kernel of an Unraid release (downloads its ~1.2 GB release zip once)
UNRAID_VERSION=7.3.2 ./build/run.sh

# or on the Unraid box / with a config copied from it
KERNEL_CONFIG=/path/to/6.18.38-Unraid.config ./build/run.sh
UNRAID_SRC=/usr/src ./build/run.sh

# add BUILD_FIRMWARE=yes to also build the firmware package (downloads ~500 MB from NVIDIA/CachyOS)
BUILD_FIRMWARE=yes UNRAID_VERSION=7.3.2 ./build/run.sh
```

Output:

```
out/6.18.38-Unraid/turing-unlock-module-2.0.0-6.18.38-Unraid-1.txz
out/firmware/turing-unlock-firmware-610.43.03-noarch-1.txz   (with BUILD_FIRMWARE=yes)
```

To use a local build on the server, copy the files to the flash and install the plugin from the
release URL:

```bash
KR=$(uname -r); MAJOR=${KR%%-*}
mkdir -p /boot/config/plugins/gpu-turing-unlock/packages/$MAJOR
cp out/$KR/*.txz out/$KR/*.sha256 /boot/config/plugins/gpu-turing-unlock/packages/$MAJOR/
mkdir -p /boot/config/plugins/gpu-turing-unlock/packages/firmware
cp out/firmware/*.txz out/firmware/*.sha256 /boot/config/plugins/gpu-turing-unlock/packages/firmware/ 2>/dev/null || true
```

Without Docker: `build/build.sh` runs on Debian/Ubuntu with the packages listed in
`build/Dockerfile` (`OUT=./out CACHE=./cache KERNEL_CONFIG=... ./build/build.sh`). The build needs
the upstream kernel tarball and Unraid's `.config`; Unraid builds without `CONFIG_MODVERSIONS` and
without module signatures, so only the vermagic has to match, and the script verifies it. The
`gcc:15` container matches the compiler Unraid 7.3.2 used (gcc 15.3.0); override with
`BASE_IMAGE=debian:trixie-slim`.

## How the pieces fit

* `build/` — config acquisition, kernel preparation, module build, Slackware packages.
* `firmware/` — vendored upstream firmware generators (GPL-2.0) plus `build-firmware.sh`. One
  source change: `hashlib.file_digest()` (Python 3.11+) is replaced with a chunked hash so Unraid
  7.3's Python 3.9 can run it.
* `plugin/` — the `.plg` template, control script, settings page and renderer.
* `.github/workflows/release.yml` — builds one module per Unraid version in parallel, renders the
  `.plg` with per-asset SHA-256 values, and publishes a GitHub release.

The plugin's control script has these commands:

```bash
/usr/local/emhttp/plugins/gpu-turing-unlock/scripts/gpu-turing-unlock \
  status|start|apply|firmware|stop
```

## Notes and limits

* **Cold boot** may be needed: if the log says the card was already initialised since power-on,
  shut down fully (not reboot), wait a few seconds, power on.
* **Display card:** the screen can stay blank from the unlock until `nvidia-drm` takes over.
  Untested with Unraid GUI mode.
* **VFIO:** a card bound to `vfio-pci` is skipped. The unlock would not survive the VM start's FLR.
* **Unraid updates:** a new kernel needs a new module package. Add the Unraid version to the
  workflow input (or tag a release) and rebuild. The firmware package is kernel-independent.
* **Remove:** Plugins page. Package files stay in
  `/boot/config/plugins/gpu-turing-unlock/packages` unless deleted. The card stays unlocked until
  it loses power.

## Credits and licences

* [nlzy/turing-unlock](https://github.com/nlzy/turing-unlock) — the module, V67 payload and firmware
  generators, GPL-2.0-only; firmware under NVIDIA's terms (`firmware/NOTICE.md`).
* [wickeddoc/gpu-unlock-unraid](https://github.com/wickeddoc/gpu-unlock-unraid) — the
  "upstream kernel + Unraid config" build method and the plugin layout this repository adapts.
* This repository's scripts and plugin: GPL-2.0-only (`LICENSE`).
