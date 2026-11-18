"""Measure first and repeated scene proofs against the current test build.

Run through run-gate.py with a fresh label. Arguments: <label> <repeats>.
Timing and tprof allocation runs use separate fresh VMs. The latter's timings
are observer-affected and must not be compared to the unprofiled timings.
"""
from pathlib import Path
import argparse
import subprocess

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("label")
parser.add_argument("repeats", type=int)
parser.add_argument("--engine-ebin", type=Path,
                    help="Explicit measurement-only erlog_int beam override")
args = parser.parse_args()
label, repeats = args.label, args.repeats
assert repeats > 0
output = root / "_build" / ("proof-scenes-" + label)
output.mkdir(exist_ok=False)
paths = sorted((root / "_build/test/lib").glob("*/ebin"))
paths += sorted((root / "_build/test/checkouts").glob("*/ebin"))
paths += [root / "_build/test/lib/quod/test", output]
if args.engine_ebin:
    paths.append(args.engine_ebin.resolve())
engine = root / "_checkouts/erlog"
if not engine.exists():
    engine = root / "_build/default/lib/erlog"
subprocess.run(["erlc", "-I", str(engine / "src"), "-o", str(output),
                str(root / "scripts/release/measure_explicit_failure_scenes.erl")], check=True)
for measurement in ["timing", "allocation"]:
    for count in [300, 600, 1200]:
        for mode in ["valid", "refused"]:
            expression = (f"measure_explicit_failure_scenes:run({count},{mode},"
                          f"{int(repeats)},{measurement}),halt().")
            subprocess.run(["erl", "-noshell", "-pa", *map(str, paths),
                            "-eval", expression], check=True)
