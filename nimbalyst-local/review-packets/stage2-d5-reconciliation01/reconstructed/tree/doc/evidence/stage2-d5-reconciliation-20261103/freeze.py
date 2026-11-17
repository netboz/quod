"""Freeze this documentation/audit slice and inspected sources, not an executable."""
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
EVIDENCE = Path(__file__).resolve().parent
PACKET = ROOT / "nimbalyst-local/review-packets/stage2-d5-reconciliation01"
PACKET.mkdir(exist_ok=False)


def run(args, label):
    p = subprocess.run(args, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    (PACKET / (label + "-stdout.log")).write_bytes(p.stdout)
    (PACKET / (label + "-stderr.log")).write_bytes(p.stderr)
    row = {"command": args, "child_exit": p.returncode, "stdout_eof": True, "stderr_eof": True}
    (PACKET / (label + ".json")).write_text(json.dumps(row, indent=2) + "\n")
    assert p.returncode == 0, row
    return row


def record(path):
    return {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "bytes": path.stat().st_size, "mode": path.stat().st_mode & 0o7777}


plan = "nimbalyst-local/plans/space-conceptual-architecture-review.md"
handoff = "nimbalyst-local/handoffs/stage2-d5-reconciliation-20261103.md"
text = (ROOT / plan).read_text()
checklist = text.split("## Implementation checklist", 1)[1].split("## Implementation tickets", 1)[0]
boxes = re.findall(r"^\s*- \[([ x])\]", checklist, re.M)
assert boxes.count("x") == 19 and len(boxes) == 25 and "progress: 76\n" in text
for doc in [ROOT / handoff]:
    for target in re.findall(r"\]\(([^)#]+)(?:#[^)]*)?\)", doc.read_text()):
        assert (doc.parent / target).is_file(), target
checks = [run(["git", "diff", "--check"], "diff-check")]
before = json.loads((EVIDENCE / "inherited-source.json").read_text())
paths = subprocess.check_output(["git", "ls-files", "-co", "--exclude-standard", "-z",
    "src", "priv", "include", "test", "client/godot", "client/godot-tests", "client/src", "client/test"], cwd=ROOT).decode().split("\0")
assert set(filter(None, paths)) == set(before)
for name, row in before.items():
    actual = record(ROOT / name)
    assert actual["sha256"] == row["sha256"] and actual["mode"] == row["mode"], name
audit = json.loads((EVIDENCE / "audit-result.json").read_text())
selected = {plan, handoff, *audit["current_owner_sources"], *audit["historical_evidence_hashes"]}
selected.update(str(p.relative_to(ROOT)) for p in EVIDENCE.rglob("*") if p.is_file())
manifest = {}
for name in sorted(selected):
    source = ROOT / name
    target = PACKET / "tree" / name
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)
    manifest[name] = record(source)
    assert record(target) == manifest[name]
(PACKET / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
archive = PACKET / "snapshot.tar"
checks.append(run(["tar", "-cf", str(archive), "-C", str(PACKET), "tree", "manifest.json"], "archive"))
restored = PACKET / "reconstructed"
restored.mkdir()
checks.append(run(["tar", "-xpf", str(archive), "-C", str(restored)], "extract"))
assert json.loads((restored / "manifest.json").read_text()) == manifest
assert {str(p.relative_to(restored / "tree")) for p in (restored / "tree").rglob("*") if p.is_file()} == set(manifest)
for name, row in manifest.items():
    assert record(restored / "tree" / name) == row, name
result = {"kind": "documentation-and-source-audit-freeze", "files": len(manifest),
          "archive": record(archive), "manifest": record(PACKET / "manifest.json"),
          "checks": checks, "reconstruction_verified": True,
          "production_delta": "+0/-0", "inherited_sources_unchanged": len(before),
          "runtime_qualification": False}
(PACKET / "result.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result))
