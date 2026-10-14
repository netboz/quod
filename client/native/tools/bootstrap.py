#!/usr/bin/env python3
"""Fetch the pinned official Godot binary/templates into the ignored client build tree."""
import hashlib
from pathlib import Path
import urllib.request
import zipfile

VERSION = "4.7.2-stable"
ARTIFACTS = {
    "linux.x86_64.zip": "cadd3204e728a35d3f13adb7fd0d7902636b79f6b95c40c265eb73b6c35329e4",
    "export_templates.tpz": "f298490b8d44d934be425a5a65a51bf15f422428b229a06a6e11d9ffea248011",
}
BASE = Path(__file__).resolve().parents[2] / "_build/godot-native/tools"


def main():
    BASE.mkdir(parents=True, exist_ok=True)
    for suffix, expected in ARTIFACTS.items():
        name = f"Godot_v{VERSION}_{suffix}"
        target = BASE / name
        if not target.exists():
            temporary = target.with_suffix(".part")
            url = f"https://github.com/godotengine/godot-builds/releases/download/{VERSION}/{name}"
            print(f"Downloading {name}", flush=True)
            with urllib.request.urlopen(url, timeout=60) as response, temporary.open("wb") as out:
                while block := response.read(1024 * 1024):
                    out.write(block)
            temporary.rename(target)
        actual = hashlib.file_digest(target.open("rb"), "sha256").hexdigest()
        if actual != expected:
            raise SystemExit(f"Checksum mismatch: {name}; artifact retained for inspection")
        with zipfile.ZipFile(target) as archive:
            for member in archive.infolist():
                # Only the Linux templates are needed; avoid unpacking other platforms.
                if suffix.endswith("tpz") and member.filename not in (
                    "templates/linux_debug.x86_64", "templates/linux_release.x86_64"
                ):
                    continue
                destination = (BASE / member.filename).resolve()
                if not destination.is_relative_to(BASE.resolve()):
                    raise SystemExit("Unsafe archive path")
                if not destination.exists():
                    archive.extract(member, BASE)
                destination.chmod(0o755)
        print(f"Verified {name}: sha256:{actual}", flush=True)


if __name__ == "__main__":
    main()
