#!/usr/bin/env python3
"""Run the offline/client integration gates sequentially with retained evidence."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--evidence", type=Path, required=True)
args = parser.parse_args()
args.evidence = args.evidence.resolve()
args.evidence.mkdir(parents=True, exist_ok=False)
root = Path(__file__).resolve().parents[3]
os.chdir(root)
python = sys.executable
tools = "client/native/tools/"
manifest = ["--manifest-path", "client/native/Cargo.toml"]
cargo = [*manifest, "--offline", "--release", "--locked"]
browser = ["accounts", "key-provider", "signed-client", "prolog-term", "marks", "glb-profile", "world", "scene", "render-resources"]
checks = [
    ("format", False, ["cargo", "fmt", *manifest, "--all", "--check"]),
    ("core", False, ["cargo", "test", *cargo, "-p", "quod-client-core"]),
    ("contracts", False, ["node", tools + "contracts.mjs"]),
    ("browser", False, ["node", "--test", "--test-concurrency=1", *[f"client/test/{name}.test.js" for name in browser]]),
    ("clippy", False, ["cargo", "clippy", *cargo, "--all-targets", "--", "-D", "warnings"]),
    ("extension", False, ["cargo", "build", *cargo]),
    ("viewer", True, [python, tools + "run.py", "--headless", "--script", "res://tests/viewer.gd"]),
    ("navigation", True, [python, tools + "run.py", "--headless", "--script", "res://tests/navigation.gd"]),
    ("tls", False, [python, tools + "connection_check.py", "--evidence", str(args.evidence / "tls-fixture")]),
    ("onboarding", False, [python, tools + "connection_check.py", "--onboarding", "--evidence", str(args.evidence / "onboarding-fixture")]),
    ("export", True, [python, tools + "run.py", "--export"]),
    ("export-start", True, [str(root / "client/native/dist/quod-native.x86_64"), "--headless", "--quit-after", "3", "--", "--node", "localhost", "--port", "14571", "--diagnostic"]),
]
env = os.environ.copy()
for name, folder in [("XDG_DATA_HOME", "data"), ("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache")]:
    path = root / "client/_build/godot-native/state" / folder
    path.mkdir(parents=True, exist_ok=True)
    env[name] = str(path)
for name, godot, command in checks:
    wrapper = [python, tools + "check.py", "--evidence", str(args.evidence / name)]
    if godot:
        wrapper += ["--godot"]
    result = subprocess.run([*wrapper, "--", *command], env=env)
    if result.returncode:
        sys.exit(result.returncode)
print("Client gates passed. Live-node and physical-XR acceptance remain separate.")
