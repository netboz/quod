#!/usr/bin/env python3
"""Run the pinned native client with project-local Godot state."""
import argparse
import os
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[3]
NATIVE = ROOT / "client/native"
BUILD = ROOT / "client/_build/godot-native"
ENGINE = BUILD / "tools/Godot_v4.7.2-stable_linux.x86_64"

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--xr", action="store_true")
parser.add_argument("--node")
parser.add_argument("--port", type=int)
parser.add_argument("--ca", help="Optional local CA certificate")
parser.add_argument("--tls-name", help="Name on the selected trusted certificate when different from the node address")
parser.add_argument("--diagnostic", action="store_true")
parser.add_argument("--headless", action="store_true")
parser.add_argument("--silent", action="store_true", help="Use Godot's Dummy audio driver for diagnostics")
parser.add_argument("--editor", action="store_true")
parser.add_argument("--script", help="Godot script path for a check")
parser.add_argument("--quit", action="store_true")
parser.add_argument("--export", action="store_true", dest="export_client")
args = parser.parse_args()
if args.port is not None and not 1 <= args.port <= 65535:
    parser.error("port must be between 1 and 65535")
if not ENGINE.exists():
    parser.error("Run tools/bootstrap.py first")
library = NATIVE / "target/release/libquod_godot.so"
if not library.exists():
    parser.error("Build the native workspace with cargo build --release --locked first")
target = NATIVE / "godot/bin/libquod_godot.so"
target.parent.mkdir(parents=True, exist_ok=True)
if not target.exists() or library.stat().st_mtime_ns != target.stat().st_mtime_ns:
    shutil.copy2(library, target)
env = os.environ.copy()
for name, folder in [("XDG_DATA_HOME", "data"), ("XDG_CONFIG_HOME", "config"), ("XDG_CACHE_HOME", "cache")]:
    path = BUILD / "state" / folder
    path.mkdir(parents=True, exist_ok=True)
    env[name] = str(path)
command = [str(ENGINE), "--path", str(NATIVE / "godot"), "--xr-mode", "on" if args.xr else "off"]
if args.headless:
    command += ["--headless"]
if args.silent:
    command += ["--audio-driver", "Dummy"]
if args.editor:
    command += ["--editor"]
if args.script:
    command += ["--script", args.script]
if args.quit:
    command += ["--quit"]
if args.export_client:
    (NATIVE / "dist").mkdir(exist_ok=True)
    command += ["--headless", "--export-release", "Linux", str(NATIVE / "dist/quod-native.x86_64")]
command += ["--"]
if args.node:
    command += ["--node", args.node]
if args.port is not None:
    command += ["--port", str(args.port)]
if args.ca:
    command += ["--ca", args.ca]
if args.tls_name:
    command += ["--tls-name", args.tls_name]
if args.xr:
    command += ["--xr"]
if args.diagnostic:
    command += ["--diagnostic"]
os.execvpe(command[0], command, env)
