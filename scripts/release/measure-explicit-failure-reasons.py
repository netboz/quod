"""Disposable experiment for QUD.85; never modifies either source checkout.

Run through run-gate.py, with a fresh evidence directory and label per step:
  ... run-gate.py <evidence> prepare python3 <this-file> prepare <evidence>
  ... run-gate.py <evidence> erlog python3 <this-file> erlog
  ... run-gate.py <evidence> eunit python3 <this-file> eunit
  ... run-gate.py <evidence> ct python3 <this-file> ct
  ... run-gate.py <evidence> erlog-runnable python3 <this-file> erlog-runnable
  ... run-gate.py <evidence> scenes-02 python3 <this-file> scenes 02
  ... run-gate.py <evidence> retain python3 <this-file> retain <evidence>
  ... run-gate.py <evidence> redact python3 <this-file> redact <evidence>
  ... run-gate.py <evidence> cleanup python3 <this-file> cleanup <evidence>

The fixed directory identifies this experiment, not a resource limit. Tests
are unchanged. Only the copied engine stops pushing automatic boundaries and
recording automatic reasons. Explicit reasons and admission stay unchanged.
"""
import hashlib
import io
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / "_build/failure-reasons-20261118"
ENGINE = WORK / "erlog"
QUOD = WORK / "quod"


def run(command, cwd):
    print(json.dumps({"cwd": str(cwd), "command": command}), flush=True)
    return subprocess.run(command, cwd=cwd).returncode


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(evidence):
    WORK.mkdir(exist_ok=False)
    archive = subprocess.check_output(["git", "archive", "HEAD"], cwd=ROOT)
    QUOD.mkdir()
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        source.extractall(QUOD, filter="data")
    shutil.copytree("/home/yan/src/erlog", ENGINE,
                    ignore=shutil.ignore_patterns(".git", "_build", "ebin"))
    original = ENGINE / "src/erlog_int.erl"
    before = original.read_text()
    modified = before.replace("predicate_failure_boundary(G, St)", "St")
    modified = modified.replace("?FAIL(add_predicate_failure_reason(G, St))", "?FAIL(St)")
    start = modified.index("predicate_failure_boundary({fail_with_reason")
    end = modified.index("%% '$'-prefixed predicates", start)
    modified = modified[:start] + "add_predicate_failure_reason(_Goal, St) -> St.\n\n" + modified[end:]
    # The unused helper bodies are intentionally retained in this experiment.
    # The plan specifies their removal in the eventual production change.
    assert before.count("predicate_failure_boundary(G, St)") == 3
    assert before.count("?FAIL(add_predicate_failure_reason(G, St))") == 1
    original.write_text(modified)
    proper = ENGINE / "_checkouts/proper"
    proper.parent.mkdir()
    shutil.copytree("/home/yan/src/erlog/_build/test/lib/proper", proper)
    deps = QUOD / "_build/default/lib"
    deps.mkdir(parents=True)
    for cached in (ROOT / "_build/default/lib").iterdir():
        if cached.name not in {"erlog", "quod"}:
            shutil.copytree(cached, deps / cached.name, symlinks=True)
    (QUOD / "_checkouts").mkdir()
    (QUOD / "_checkouts/erlog").symlink_to(ENGINE)
    # Reuse only the derived Rust build cache; the source snapshot is separate.
    (QUOD / "native/quod_physics/target").symlink_to(ROOT / "native/quod_physics/target")
    manifest = {
        "quod_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "erlog_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd="/home/yan/src/erlog", text=True).strip(),
        "erlog_original_sha256": hashlib.sha256(before.encode()).hexdigest(),
        "erlog_experimental_sha256": digest(original),
        "uptime": subprocess.check_output(["uptime"], text=True).strip(),
        "work": str(WORK),
    }
    evidence = Path(evidence).resolve()
    (evidence / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    import difflib
    (evidence / "engine-experiment.patch").write_text("".join(difflib.unified_diff(
        before.splitlines(True), modified.splitlines(True),
        fromfile="original/src/erlog_int.erl", tofile="experiment/src/erlog_int.erl")))
    print(json.dumps(manifest), flush=True)
    return 0


def test_paths():
    return (sorted(str(p) for p in (QUOD / "_build/test/lib").glob("*/ebin"))
            + sorted(str(p) for p in (QUOD / "_build/test/checkouts").glob("*/ebin"))
            + [str(QUOD / "_build/test/lib/quod/test")])


def scenes(label):
    helper = ROOT / "scripts/release/measure_explicit_failure_scenes.erl"
    ebin = WORK / ("scene-ebin-" + label)
    ebin.mkdir()
    paths = test_paths()
    result = run(["erlc", "-I", str(ENGINE / "src"), "-o", str(ebin), str(helper)], QUOD)
    if result:
        return result
    result = run(["erl", "-noshell", "-pa", *paths, str(ebin), "-eval",
                  "measure_explicit_failure_scenes:contract(),halt()."], QUOD)
    if result:
        return result
    for size in [300, 600, 1200]:
        for mode in ["valid", "refused"]:
            expression = f"measure_explicit_failure_scenes:run({size},{mode}),halt()."
            result = run(["erl", "-noshell", "-pa", *paths, str(ebin),
                          "-eval", expression], QUOD)
            if result:
                return result
    # The full suite uses compact output. This named case records its elapsed
    # time under the unchanged EUnit timeout, the rendering margin obligation.
    expression = ("case eunit:test({quod_rendering_tests,"
                  "complete_scenes_and_authored_resources_test},[verbose]) "
                  "of ok -> halt(0); _ -> halt(1) end.")
    return run(["erl", "-noshell", "-pa", *paths, str(ebin),
                "-eval", expression], QUOD)


def isolated(modules):
    failures = []
    for target in modules:
        module, separator, generator = target.partition(":")
        assert module.replace("_", "").isalnum()
        assert (QUOD / "test" / (module + ".erl")).is_file()
        if separator:
            assert generator.replace("_", "").isalnum()
        test = f"{module}:{generator}()" if separator else module
        expression = (f'io:format("engine=~p~n",[code:which(erlog_int)]),'
                      f"case eunit:test({test},[verbose]) "
                      "of ok -> halt(0); _ -> halt(1) end.")
        status = run(["erl", "-noshell", "-pa", *test_paths(), "-eval", expression], QUOD)
        print(json.dumps({"target": target, "exit_code": status}), flush=True)
        if status:
            failures.append(target)
    print(json.dumps({"isolated_failures": failures}), flush=True)
    return 1 if failures else 0


def erlog_runnable():
    # The unmodified records_test.erl requires proprietary eqc headers absent
    # from the checkout. Keep its failed full-suite run; run all standalone
    # EUnit modules without changing or excluding tests within those modules.
    modules = sorted((ENGINE / "test").glob("erlog_*_tests.erl"))
    ebin = WORK / "erlog-test-ebin"
    ebin.mkdir()
    result = run(["erlc", "-I", str(ENGINE / "src"), "-o", str(ebin),
                  *map(str, modules)], ENGINE)
    if result:
        return result
    names = ",".join(p.stem for p in modules)
    expression = f"case eunit:test([{names}],[verbose]) of ok -> halt(0); _ -> halt(1) end."
    return run(["erl", "-noshell", "-pa", str(ebin),
                str(ENGINE / "_build/test/lib/erlog/ebin"),
                "-eval", expression], ENGINE)


def retain(evidence):
    evidence = Path(evidence).resolve()
    logs = QUOD / "_build/test/logs"
    if logs.exists():
        # CT's log_private contains temporary ledgers, caches and generated
        # test identities, not the suite/case logs. Keep the logs, not a second
        # copy of the disposable runtime data.
        shutil.copytree(logs, evidence / "ct-logs", symlinks=True,
                        ignore=shutil.ignore_patterns("log_private"))
    beams = [ENGINE / "_build/test/lib/erlog/ebin/erlog_int.beam",
             QUOD / "_build/test/checkouts/erlog/ebin/erlog_int.beam"]
    (evidence / "compiled-engine-hashes.json").write_text(json.dumps(
        {str(p.relative_to(WORK)): digest(p) for p in beams}, indent=2) + "\n")
    assert digest(ENGINE / "src/erlog_int.erl") != digest(Path("/home/yan/src/erlog/src/erlog_int.erl"))
    print("Retained CT logs and compiled-engine hashes; original source remains distinct.")
    return 0


def redact(evidence):
    evidence = Path(evidence).resolve()
    receipt = evidence / "redactions.json"
    if receipt.exists():
        raise SystemExit("Refusing to overwrite redaction evidence")
    # Erlang can print a binary as octets, a quoted string, or a mixture.
    # A closing-binary token inside a quoted string is still private data.
    quoted = r'"(?:\\.|[^"\\])*"'
    html_quoted = rf'(?:{quoted}|&quot;(?:(?!&quot;).)*&quot;)'
    patterns = [
        re.compile(rf"('ECPrivateKey',\s*\d+,\s*)(<<(?:{quoted}|(?!>>).)*>>)", re.S),
        re.compile(rf"('ECPrivateKey',\s*\d+,\s*)(&lt;&lt;(?:{html_quoted}|(?!&gt;&gt;).)*&gt;&gt;)", re.S),
    ]
    changed = []
    for path in sorted(evidence.rglob("*")):
        if not path.is_file() or path.suffix not in {".log", ".html"}:
            continue
        original = path.read_text()
        redacted = original
        count = 0
        for pattern in patterns:
            def replace(match):
                # Preserve line numbers used by the failure inventory.
                return (match[1] + "[REDACTED_GENERATED_TEST_PRIVATE_KEY]"
                        + "\n" * match[2].count("\n"))
            redacted, found = pattern.subn(replace, redacted)
            count += found
        if count:
            assert original.count("\n") == redacted.count("\n")
            before = digest(path)
            path.write_text(redacted)
            changed.append({"path": str(path.relative_to(evidence)),
                            "private_key_octet_strings": count,
                            "original_sha256": before, "redacted_sha256": digest(path)})
    receipt.write_text(json.dumps(changed, indent=2) + "\n")
    print(json.dumps({"files": len(changed), "private_key_octet_strings":
                      sum(row["private_key_octet_strings"] for row in changed)}), flush=True)
    return 0


def cleanup(evidence):
    evidence = Path(evidence).resolve()
    text = "\n".join((evidence / name).read_text()
                     for name in ["quod-eunit-01.log", "isolated-01.log"])
    # Only exact paths emitted by our failed fixture owners are authorized;
    # never glob or remove unrelated /tmp/quod* directories.
    paths = sorted(set(re.findall(
        r"Failed hosted-agent fixture retained at (/tmp/quod_hosted_[0-9A-F]+)", text)))
    removed = []
    for name in paths:
        path = Path(name)
        assert path.parent == Path("/tmp") and not path.is_symlink()
        if path.is_dir():
            shutil.rmtree(path)
            removed.append(name)
    shutil.rmtree(WORK)
    with (evidence / "cleanup.json").open("x") as output:
        json.dump({"removed_build_tree": str(WORK),
                   "removed_logged_failed_fixtures": removed}, output, indent=2)
        output.write("\n")
    print(json.dumps({"removed_build_tree": str(WORK),
                      "removed_logged_failed_fixtures": len(removed)}), flush=True)
    return 0


if __name__ == "__main__":
    step = sys.argv[1]
    if step == "prepare":
        result = prepare(sys.argv[2])
    elif step == "erlog":
        result = run(["rebar3", "eunit"], ENGINE)
    elif step == "erlog-runnable":
        result = erlog_runnable()
    elif step in {"eunit", "ct"}:
        result = run(["rebar3", "as", "test", step], QUOD)
    elif step == "scenes":
        result = scenes(sys.argv[2])
    elif step == "isolated":
        result = isolated(sys.argv[2:])
    elif step == "retain":
        result = retain(sys.argv[2])
    elif step == "redact":
        result = redact(sys.argv[2])
    elif step == "cleanup":
        result = cleanup(sys.argv[2])
    else:
        raise SystemExit("Unknown step: " + step)
    raise SystemExit(result)
