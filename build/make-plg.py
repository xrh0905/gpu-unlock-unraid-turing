#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Render the Unraid .plg from the template, built packages and firmware scripts."""
from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path
from xml.sax.saxutils import escape

PLUGIN = "gpu-turing-unlock"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def cdata(text: str, name: str) -> str:
    if "]]>" in text:
        raise SystemExit(f"{name} contains ']]>' and cannot be embedded in CDATA")
    return "<![CDATA[\n" + text.rstrip("\n") + "\n]]>"


def file_entry(name: str, mode: str | None, body: str) -> str:
    mode_attr = f' Mode="{mode}"' if mode else ""
    return f'<FILE Name="{name}"{mode_attr}>\n<INLINE>{body}</INLINE>\n</FILE>\n'


def download_entry(name: str, url: str, checksum: str) -> str:
    return (f'<FILE Name="{name}">\n<URL>{url}</URL>\n'
            f'<SHA256>{checksum}</SHA256>\n</FILE>\n')


def package_entries(packages: Path, release_url: str, plugin: str) -> tuple[str, list[Path]]:
    entries: list[str] = []
    assets: list[Path] = []
    for txz in sorted(packages.glob("*/*.txz")):
        major = txz.parent.name
        sidecar = txz.with_name(txz.name + ".sha256")
        if not sidecar.is_file():
            raise SystemExit(f"missing {sidecar}")
        for path in (txz, sidecar):
            target = f"/boot/config/plugins/{plugin}/packages/{major}/{path.name}"
            entries.append(download_entry(target, f"{release_url}/{path.name}", sha256(path)))
            assets.append(path)
    if not entries:
        raise SystemExit(f"no .txz packages under {packages}")
    return "\n".join(entries), assets


def firmware_entries(firmware_dir: Path, plugin: str) -> str:
    entries: list[str] = []
    for path in sorted(firmware_dir.iterdir()):
        if not path.is_file():
            continue
        mode = "0755" if path.suffix == ".sh" else "0644"
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            raise SystemExit(f"{path} is not UTF-8 text")
        entries.append(file_entry(f"/usr/local/emhttp/plugins/{plugin}/firmware/{path.name}",
                                  mode, cdata(text, str(path))))
    if not entries:
        raise SystemExit(f"no firmware files in {firmware_dir}")
    return "\n".join(entries)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--release-url", required=True, help="release download URL without a trailing slash")
    parser.add_argument("--plugin-url", required=True)
    parser.add_argument("--packages", type=Path, required=True)
    parser.add_argument("--template", type=Path, required=True)
    parser.add_argument("--plugin-dir", type=Path, required=True)
    parser.add_argument("--firmware-dir", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--changes-file", type=Path)
    parser.add_argument("--upstream-version", default="2.0.0")
    parser.add_argument("--upstream-ref", default="")
    args = parser.parse_args()

    release_url = args.release_url.rstrip("/")
    template = args.template.read_text(encoding="utf-8")
    plugins = package_entries(args.packages, release_url, PLUGIN)[0]
    firmware = firmware_entries(args.firmware_dir, PLUGIN)

    control = (args.plugin_dir / "scripts" / PLUGIN).read_text(encoding="utf-8")
    page = (args.plugin_dir / "GPUUnlock.page").read_text(encoding="utf-8")

    if args.changes_file:
        changes = args.changes_file.read_text(encoding="utf-8").strip()
    else:
        kernels = sorted({p.parent.name for p in args.packages.glob("*/*.txz") if p.parent.name != "firmware"})
        changes = (
            f"###{args.version}\n"
            f"- turing-unlock {args.upstream_version}"
            + (f" ({args.upstream_ref[:12]})" if args.upstream_ref else "")
            + "\n- Module packages for Unraid kernels: " + ", ".join(kernels) + "\n"
            + "- After an Unraid OS update, watch /boot/changes.txt and fetch the module for the new kernel from the latest release before the reboot.\n"
        )
        if any(args.packages.glob("firmware/*.txz")):
            changes += "- Firmware package: pinned NVIDIA 610.43.03 (NVIDIA terms; see NOTICE.md).\n"

    rendered = template
    for needle, value in {
        "@@VERSION@@": args.version,
        "@@PLUGIN_URL@@": args.plugin_url,
        "@@PACKAGE_FILES@@": plugins,
        "@@CONTROL_SCRIPT@@": cdata(control, "control script"),
        "@@PAGE@@": cdata(page, "settings page"),
        "@@FIRMWARE_FILES@@": firmware,
        "@@CHANGES@@": escape(changes),
    }.items():
        rendered = rendered.replace(needle, value)
    if "@@" in rendered:
        raise SystemExit("unreplaced placeholder remains in the rendered plugin")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(rendered, encoding="utf-8")
    print(args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
