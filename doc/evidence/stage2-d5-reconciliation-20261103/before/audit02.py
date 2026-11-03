"""Read-only source/evidence reconciliation; does not launch runtime tests."""
import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads((ROOT / path).read_text())


before = json.loads((OUT / "inherited-source.json").read_text())
for name, row in before.items():
    p = ROOT / name
    assert digest(p) == row["sha256"], name
    assert p.stat().st_mode & 0o7777 == row["mode"], name
for args, saved in [([], "inherited-tracked.patch"), (["--cached"], "inherited-index.patch")]:
    assert subprocess.check_output(["git", "diff", *args, "--binary", "--", ".", ":(exclude)nimbalyst-local/plans/space-conceptual-architecture-review.md"], cwd=ROOT) == (OUT / saved).read_bytes()

base = "doc/evidence/godot-m3b-20261029/"
stage = "doc/evidence/godot-space-stage2-20261031/"
navigation = read(base + "final-navigation-final03/phases.json")
assert [p["child_exit"] for p in navigation] == [-9, -9, -9, 0, 0, 0]
assert all(p["passed"] and p["child_exit"] == p["expected_exit"] for p in navigation)
work_paths = [base + "final-navigation-final03/recursive-scene.png.work.json",
              base + "physics-final03/client-result.json.renewals.json"]
assert all(read(p)["work"]["calls"] == [] for p in work_paths)
physical = read(base + "physics-final03/client-result.json")
assert physical["passed"] and len(physical["checks"]) == 29
stage_result = read(stage + "result.json")
selected = {}
evidence = [base + "qualification.json", base + "failure-dispositions.md",
            base + "final-navigation-final03/phases.json",
            base + "final-navigation-final03/m3-left-result.json",
            base + "final-navigation-final03/m3-final-result.json",
            base + "physics-final03/client-result.json", *work_paths,
            stage + "result.json", stage + "failure-disposition.md"]
for label in ["stage2-final03-contents", "stage2-final01-headless"]:
    row = stage_result["rehearsals"][label]
    assert row["passed"] and all(v == 0 for v in row["children"].values())
    assert all(row["eof"].values()) and not row["reader_errors"]
    receipt = Path(row["receipt"]["path"])
    assert digest(receipt) == row["receipt"]["sha256"]
    evidence.append(str(receipt.relative_to(ROOT)))
    selected[label] = {k: row[k] for k in ["children", "eof", "checks", "prior_checks"]}

owners = ["priv/ontologies/quod_space.pl", "priv/ontologies/common_predicates.pl",
          "priv/ontologies/space_physics.pl", "priv/ontologies/gui_scene.pl",
          "src/quod_client_view.erl", "src/quod_runtime.erl", "src/quod_physics.erl",
          "src/quod_physics_frames.erl", "client/godot/Core/Scene.cs",
          "client/godot/Core/World.cs", "client/godot/Core/SignedView.cs",
          "client/godot/Core/Eidolons.cs", "client/godot/ScenePanel.cs",
          "client/godot/Main.cs", "test/quod_physics_tests.erl",
          "client/godot/tests/NavigationChecks.cs", "client/godot/tests/PhysicsChecks.cs"]
comparison = {}
for name in owners:
    old = subprocess.check_output(["git", "show", "HEAD:" + name], cwd=ROOT, stderr=subprocess.DEVNULL) if name != "client/godot/Core/Eidolons.cs" else None
    comparison[name] = {"sha256": digest(ROOT / name), "equals_committed_m3": old == (ROOT / name).read_bytes()}
space = (ROOT / owners[0]).read_text()
old_space = subprocess.check_output(["git", "show", "HEAD:" + owners[0]], cwd=ROOT).decode()
assert space[space.index("space_scene_parts([]," ):] == old_space[old_space.index("space_scene_parts([]," ):]

client_manifest = read(stage + "inputs/client-stage2-product01-manifest.json")
client_comparison = {name: digest(ROOT / name) == sha
                     for name, sha in client_manifest["live_source_inputs"].items()}
result = {"kind": "source-and-retained-evidence-audit-not-runtime-qualification",
          "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT).decode().strip(),
          "inherited_source_paths_unchanged": len(before), "production_delta": {"added": 0, "removed": 0},
          "navigation_child_exits": [p["child_exit"] for p in navigation],
          "historical_stage2_results": selected, "historical_physical_checks": len(physical["checks"]),
          "historical_unchanged_work": {p: read(p) for p in work_paths},
          "current_owner_sources": comparison, "recursive_traversal_equals_committed_m3": True,
          "stage2_product01_current_source_comparison": client_comparison,
          "historical_evidence_hashes": {p: digest(ROOT / p) for p in evidence},
          "new_runtime_runs": 0, "new_failing_baseline": None,
          "limit": "Later inherited sources differ from historical qualified trees. No fresh whole-tree acceptance or new runtime defect is claimed."}
(OUT / "audit-result.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps({"audit": "passed", "source_paths_unchanged": len(before),
                  "production_delta": "+0/-0", "new_runtime_runs": 0,
                  "historical_stage2_inputs_now_changed": sum(not v for v in client_comparison.values())}))
