#!/usr/bin/env python3
"""Download the pinned Fluent package and deterministically rebuild Keywork."""

import base64
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
META = ROOT / "design/fluent"
OUTPUT = ROOT / "resources/icons/Keywork"
STEM = re.compile(r"^(.+)_(\d+)_(regular|filled|light|color)\.svg$")


def safe_members(archive):
    for member in archive.getmembers():
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or member.issym() or member.islnk():
            raise RuntimeError(f"unsafe archive member: {member.name}")
        if member.isfile() and len(path.parts) >= 3 and path.parts[:2] == ("package", "icons") and path.suffix == ".svg":
            yield member


def main():
    lock = json.loads((META / "package-lock.json").read_text())
    aliases = json.loads((META / "aliases.json").read_text())
    with urllib.request.urlopen(lock["url"]) as response:
        payload = response.read()
    expected = base64.b64decode(lock["integrity"].removeprefix("sha512-"))
    if hashlib.sha512(payload).digest() != expected:
        raise RuntimeError("download does not match pinned SHA-512 integrity")

    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as archive:
        members = sorted(safe_members(archive), key=lambda m: m.name)
        if len(members) != lock["svg_count"]:
            raise RuntimeError(f"expected {lock['svg_count']} SVGs, found {len(members)}")
        assets = {}
        for member in members:
            path = PurePosixPath(member.name)
            filename = path.name
            match = STEM.match(filename)
            if not match:
                raise RuntimeError(f"unexpected SVG name: {filename}")
            relative = path.relative_to("package/icons").with_suffix("")
            assets[str(relative)] = archive.extractfile(member).read()

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix="keywork-icons-", dir=OUTPUT.parent))
    try:
        directories = set()
        for relative, data in sorted(assets.items()):
            stem = PurePosixPath(relative).name
            match = STEM.match(stem + ".svg")
            size = int(match.group(2))
            directory = f"{size}x{size}/fluent"
            directories.add(directory)
            destination = tmp / directory / f"{relative}.svg"
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)

        for name, spec in sorted(aliases.items()):
            target, context = spec[:2]
            candidates = sorted((s for s in assets if "/" not in s and re.fullmatch(re.escape(target) + r"_\d+_regular", s)), key=lambda s: int(s.rsplit("_", 2)[1]))
            if not candidates:
                raise RuntimeError(f"alias {name} target does not exist: {target}")
            for stem in candidates:
                size = int(stem.rsplit("_", 2)[1])
                directory = f"{size}x{size}/{context}"
                directories.add(directory)
                out = tmp / directory
                out.mkdir(parents=True, exist_ok=True)
                for alias_name in (name, name + "-symbolic"):
                    (out / f"{alias_name}.svg").write_bytes(assets[stem])

        # Battery level names use Fluent's 0..10 scale. Generic charge is used
        # only if a level-specific charging glyph is absent.
        for level in range(0, 101, 10):
            add_battery_alias(tmp, directories, assets, f"battery-level-{level}", f"battery_{level // 10}", None)
            add_battery_alias(
                tmp,
                directories,
                assets,
                f"battery-level-{level}-charging",
                f"battery_charge_{level // 10}",
                "battery_charge",
            )
        add_battery_alias(tmp, directories, assets, "battery-full-charging", "battery_charge_10", "battery_charge")
        add_battery_alias(tmp, directories, assets, "battery-level-100-plugged-in", "battery_charge_10", "battery_charge")

        directory_list = sorted(directories, key=lambda d: (int(d.split("x", 1)[0]), d))
        lines = ["[Icon Theme]", "Name=Keywork", "Comment=Fluent System Icons packaged for Keywork", "Inherits=Adwaita,hicolor", "Directories=" + ",".join(directory_list), ""]
        for directory in directory_list:
            size = directory.split("x", 1)[0]
            context = directory.rsplit("/", 1)[1]
            lines += [f"[{directory}]", f"Size={size}", "Type=Fixed"]
            if context != "fluent":
                lines.append("Context=" + ("MimeTypes" if context == "mimetypes" else context.title()))
            lines.append("")
        (tmp / "index.theme").write_text("\n".join(lines), newline="\n")
        shutil.copyfile(META / "LICENSE", tmp / "LICENSE")
        if OUTPUT.exists():
            shutil.rmtree(OUTPUT)
        tmp.rename(OUTPUT)
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    print(f"generated {len(assets)} Fluent SVGs and {len(aliases) + 24} XDG alias names")


def add_battery_alias(root, directories, assets, name, target, fallback):
    candidates = sorted((s for s in assets if "/" not in s and re.fullmatch(re.escape(target) + r"_\d+_regular", s)), key=lambda s: int(s.rsplit("_", 2)[1]))
    if not candidates and fallback:
        candidates = sorted((s for s in assets if "/" not in s and re.fullmatch(re.escape(fallback) + r"_\d+_regular", s)), key=lambda s: int(s.rsplit("_", 2)[1]))
    if not candidates:
        raise RuntimeError(f"battery alias {name} has no target {target}")
    for stem in candidates:
        size = int(stem.rsplit("_", 2)[1])
        directory = f"{size}x{size}/status"
        directories.add(directory)
        out = root / directory
        out.mkdir(parents=True, exist_ok=True)
        for alias in (name, name + "-symbolic"):
            (out / f"{alias}.svg").write_bytes(assets[stem])


if __name__ == "__main__":
    main()
