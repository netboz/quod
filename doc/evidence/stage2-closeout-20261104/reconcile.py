"""Bind Stage 2 closeout to retained source and child-exit evidence."""

from pathlib import Path
import hashlib
import json


ROOT = Path(__file__).resolve().parents[3]
EVIDENCE = ROOT / "doc/evidence"


def read_json(path):
    return json.loads(path.read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def differences(inputs):
    return sorted(path for path, expected in inputs.items()
                  if not (ROOT / path).is_file()
                  or digest(ROOT / path) != expected)


def receipt(name, path):
    value = read_json(path)
    return {"name": name, "path": str(path.relative_to(ROOT)),
            "sha256": digest(path), "true_exit": value["true_exit"],
            "stdout_eof": value["stdout_eof"],
            "stderr_eof": value["stderr_eof"]}


candidate_path = EVIDENCE / "stage2-renewal-diagnosis-20261103/inputs/configured-candidate04.json"
aggregate_path = EVIDENCE / "stage2-renewal-diagnosis-20261103/inputs/configured-aggregate02.json"
client_path = EVIDENCE / "stage2-renewal-diagnosis-20261103/inputs/client-aggregate01-build.json"
predicate_path = EVIDENCE / "stage2-predicate-removal-20261103/inputs/final-source.json"
long_dir = EVIDENCE / "stage2-limit-audit-20261104/inputs"
final_dir = EVIDENCE / "stage2-finalization-20261103"

candidate = read_json(candidate_path)
aggregate = read_json(aggregate_path)
client = read_json(client_path)
predicate = read_json(predicate_path)
fixed = read_json(long_dir / "source-long-fixed03.json")

predicate_production = sorted(set(predicate["production_files"]) &
                              set(candidate["source_inputs"]))
predicate_tests = sorted(set(predicate["test_files"]) &
                         set(candidate["source_inputs"]))
expected_candidate_differences = sorted(
    predicate_production + predicate_tests +
    ["src/quod_client_view.erl", "test/quod_source_view_tests.erl",
     "src/predicates/quod_ask.erl", "rebar.config", "rebar.lock"])
candidate_differences = differences(candidate["source_inputs"])
assert candidate_differences == expected_candidate_differences
assert differences(predicate["production_files"]) == []
assert differences(predicate["test_files"]) == []
assert differences(predicate["final_compiled_source_inputs"]) == [
    "src/quod_client_view.erl", "test/quod_source_view_tests.erl"]
assert differences(fixed["source_inputs"]) == []

client_differences = differences(client["source_inputs"])
assert client_differences == ["client/test/fixtures/native-contract/contracts.json"]
assert differences(client["diagnostic_inputs"]) == [
    "client/godot/tests/ExportChecks.cs", "client/godot/tests/LimitsChecks.cs"]
for label in ["core02", "admission02", "managed-build02"]:
    assert differences(read_json(final_dir / (label + ".json"))["source_inputs"]) == []

comment = read_json(EVIDENCE / "stage2-renewal-delivery-20261103/comment-correction01.json")
assert candidate["source_inputs"][comment["path"]] == comment["before"]
assert digest(ROOT / comment["path"]) == comment["after"]

pin = "79b3874617a4eb9f76d5089a3fc908667e605e8a"
assert pin in (ROOT / "rebar.config").read_text()
assert pin in (ROOT / "rebar.lock").read_text()
assert aggregate["passed"] is True and len(aggregate["checks"]) == 29
assert all(child["true_exit"] == 0 for child in aggregate["children"].values())
assert all(aggregate["eof"].values())

receipts = [
    receipt("configured-candidate04", candidate_path),
    receipt("source-long-baseline03", long_dir / "source-long-baseline03.json"),
    receipt("source-long-fixed03", long_dir / "source-long-fixed03.json"),
    receipt("source-long-production01", long_dir / "source-long-production01.json"),
    *[receipt(label, final_dir / (label + ".json"))
      for label in ["core02", "admission02", "managed-build02"]],
]
assert receipts[0]["true_exit"] == 0
assert receipts[1]["true_exit"] == 1
assert all(item["true_exit"] == 0 for item in receipts[2:])
assert all(item["stdout_eof"] and item["stderr_eof"] for item in receipts)

result = {
    "basis": "Read-only source/evidence reconciliation; no runtime test was rerun",
    "candidate_source_count": len(candidate["source_inputs"]),
    "candidate_differences": candidate_differences,
    "candidate_difference_owners": {
        "predicate_removal_production": predicate_production,
        "predicate_removal_tests": predicate_tests,
        "long_name_view": ["src/quod_client_view.erl", "test/quod_source_view_tests.erl"],
        "pin": ["rebar.config", "rebar.lock"],
        "comment_only": ["src/predicates/quod_ask.erl"],
    },
    "predicate_final_compiled_source_count": len(predicate["final_compiled_source_inputs"]),
    "predicate_final_differences": differences(predicate["final_compiled_source_inputs"]),
    "client_aggregate_source_count": len(client["source_inputs"]),
    "client_aggregate_differences": client_differences,
    "client_diagnostic_differences": differences(client["diagnostic_inputs"]),
    "current_client_core_source_count": len(read_json(final_dir / "core02.json")["source_inputs"]),
    "aggregate": {"path": str(aggregate_path.relative_to(ROOT)),
                  "sha256": digest(aggregate_path), "passed": True,
                  "checks": len(aggregate["checks"]),
                  "child_exits": {name: value["true_exit"]
                                  for name, value in aggregate["children"].items()},
                  "eof": aggregate["eof"]},
    "receipts": receipts,
    "current_changed_source_sha256": {
        path: digest(ROOT / path) for path in
        ["src/quod_client_view.erl", "test/quod_source_view_tests.erl"]},
    "erlog_pin": pin,
}
(Path(__file__).parent / "source-reconciliation.json").write_text(
    json.dumps(result, indent=2) + "\n")
print("PASS: 676 candidate inputs, 446 predicate inputs, 98 client inputs and 29 signed checks reconciled")
