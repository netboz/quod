#!/usr/bin/env python3
"""Run one check, retaining full output and the true child exit in a new directory."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--evidence", type=Path, required=True)
parser.add_argument("--godot", action="store_true", help="Fail on Godot error diagnostics even if the engine exits zero")
parser.add_argument("command", nargs=argparse.REMAINDER)
args = parser.parse_args()
command = args.command[1:] if args.command[:1] == ["--"] else args.command
if not command:
    parser.error("a command is required")
args.evidence.mkdir(parents=True, exist_ok=False)
start = time.monotonic()
with (args.evidence / "output.log").open("wb") as log:
    child = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
output = (args.evidence / "output.log").read_text(errors="replace")
diagnostic_failure = args.godot and ("ERROR:" in output or "SCRIPT ERROR:" in output)
result = {"command": command, "exit": child.returncode, "diagnostic_failure": diagnostic_failure, "elapsed_seconds": time.monotonic() - start}
(args.evidence / "result.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result))
if child.returncode or diagnostic_failure:
    print(output[-10000:])
sys.exit((child.returncode if child.returncode >= 0 else 128-child.returncode) or int(diagnostic_failure))
