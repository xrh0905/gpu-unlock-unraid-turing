# Firmware generators

These files are vendored from [nlzy/turing-unlock](https://github.com/nlzy/turing-unlock)
at commit `417f333263ff169e8f449c931b70db9dfd7b8ef4` (v2.0.0), GPL-2.0-only:

| File | Purpose |
|---|---|
| `fetch_artifacts.py` | Downloads the pinned NVIDIA source archive and CachyOS `nvidia-utils` package, verifying SHA-256. |
| `generate_v67.py` | Extracts `gsp_tu10x.bin` and generates the TU102 V67 image. |
| `extract_boot_assets.py` | Builds the TU102 Booter/GSP boot images and `sec2_bl_tu102.bin`. |
| `artifacts-610.43.03.json` | Pins every input/output SHA-256 and the NVIDIA license. |
| `NOTICE.md` | Upstream's firmware provenance and distribution note. |
| `build-firmware.sh` | Runs the three scripts and packs the Unraid `.txz`. |

The only source change is in `fetch_artifacts.py`: `hashlib.file_digest()` (Python 3.11+) is
replaced with a chunked `hashlib.sha256()` loop so the script runs on Unraid 7.3's Python 3.9.

`build-firmware.sh` does not redistribute anything itself. It downloads from NVIDIA and CachyOS on
the machine that builds the package, checks the pinned hashes, and writes the package locally. This
repository's release workflow does publish the generated package; see the root README for the
licensing caveat. NVIDIA's firmware license is installed next to the files; read `NOTICE.md`.
