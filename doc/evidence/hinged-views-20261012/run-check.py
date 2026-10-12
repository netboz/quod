#!/usr/bin/env python3
"""Run one labeled sequential check, retaining failures and source fences."""
import datetime, hashlib, json, os, subprocess, sys
from pathlib import Path
root = Path(__file__).resolve().parents[3]
out = Path(__file__).resolve().parent / sys.argv[1]
out.mkdir()
sources = ["priv/ontologies/quod_physics.pl", "priv/ontologies/quod_hinged.pl",
           "src/quod_physics.erl", "src/quod_physics_native.erl", "src/quod_runtime.erl",
           "native/quod_physics/src/lib.rs", "native/quod_physics/src/geometry.rs",
           "test/quod_physics_tests.erl", "test/quod_lobby_tests.erl",
           "test/fixtures/hinged-door.pl", "test/fixtures/hinged-lid.pl",
           "priv/ontologies/hinged_example_view.pl"]
def hashes():
    return {p: hashlib.sha256((root / p).read_bytes()).hexdigest() for p in sources}
manifest = hashes()
(out / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
command = sys.argv[2:]
start = datetime.datetime.now(datetime.timezone.utc).isoformat()
env = dict(os.environ)
env.pop("LD_LIBRARY_PATH", None)
env.pop("LD_PRELOAD", None)
with (out / "check.log").open("w") as log:
    result = subprocess.run(command, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
receipt = dict(command=command, started=start,
               finished=datetime.datetime.now(datetime.timezone.utc).isoformat(),
               child_exit=result.returncode, sources_unchanged=hashes() == manifest)
(out / "result.json").write_text(json.dumps(receipt, indent=2) + "\n")
if result.returncode or not receipt["sources_unchanged"]:
    (out / "STOP").write_text("Failed check or changed source fence; retained for diagnosis.\n")
print(json.dumps(receipt))
sys.exit(result.returncode or (0 if receipt["sources_unchanged"] else 2))
