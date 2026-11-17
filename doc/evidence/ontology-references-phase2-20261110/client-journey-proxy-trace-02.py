"""Run the existing exported-client journey against the current local fixture."""
import glob
import json
import os
import pathlib
import queue
import subprocess
import sys
import tempfile
import threading

evidence = pathlib.Path(__file__).resolve().parent
root = evidence.parents[2]
label, journey = sys.argv[1:]
receipt = evidence / (label + "-result.json")
if receipt.exists():
    raise SystemExit("Refusing to overwrite " + str(receipt))
private = pathlib.Path(tempfile.mkdtemp(prefix="pearl-client-"))
objects = private / "ebin"
objects.mkdir()
factory = root / "test/quod_lifecycle_single_path_tests.erl"
source = factory.read_text()
before = "_ = file:del_dir_r(Dir),\n    ok."
assert source.count(before) == 1
retained = private / factory.name
retained.write_text(source.replace(before, "ok."))
paths = sorted(glob.glob(str(root / "_build/test/lib/*/ebin")))
paths += [str(root / "_build/test/lib/quod/test")]
compile_command = ["erlc", *[arg for path in paths for arg in ("-pa", path)], "+export_all", "-I", str(root / "include"),
                   "-o", str(objects), str(retained),
                   str(root / "test/quod_physics_tests.erl"), str(evidence / "godot_m3b_fixture.erl")]
result = {"private_fixture": str(private), "journey": journey, "compile_command": compile_command}
with (evidence / (label + "-compile.log")).open("xb") as log:
    compiled = subprocess.run(compile_command, cwd=root, stdout=log, stderr=subprocess.STDOUT)
result["compile_exit"] = compiled.returncode
if compiled.returncode:
    receipt.write_text(json.dumps(result, indent=2) + "\n")
    raise SystemExit(compiled.returncode)
command = ["erl", "-noshell", "-pa", *paths, str(objects), "-eval", "godot_m3b_fixture:start(),halt()."]
result["server_command"] = command
server = subprocess.Popen(command, cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True,
                          env=dict(os.environ, QUOD_M3B_PRIVATE=str(private)))
lines = queue.Queue()
def receive():
    with (private / "server.log").open("x") as log:
        for line in server.stdout:
            log.write(line)
            log.flush()
            if line.startswith("M1B_READY "):
                lines.put(json.loads(line[len("M1B_READY "):]))
    lines.put(None)
threading.Thread(target=receive, daemon=True).start()
try:
    ready = lines.get(timeout=60)
    if ready is None:
        raise RuntimeError("Fixture ended before readiness; see " + str(private / "server.log"))
    print("Local fixture ready", flush=True)
    client = [sys.executable, "/tmp/pearl-phase2-proxy-trace-02.py", str(root / "client/godot-tests/journey.py"),
              "--journey", journey, "--export", str(root / "client/godot/dist/quod.x86_64"),
              "--backend-port", str(ready["port"]), "--backend-ca", ready["ca"],
              "--control-port", str(ready["control_port"]), "--network=" + ready["network"],
              "--evidence", str(evidence / label), "--private", str(private / "client")]
    if journey == "gui":
        client.append("--controllers")
    result["client_command"] = client
    result["client_exit"] = subprocess.run(client, cwd=root).returncode
except Exception as error:
    result["failure"] = str(error)
finally:
    try:
        if server.poll() is None:
            server.stdin.write("stop\n")
            server.stdin.flush()
        result["server_exit"] = server.wait(timeout=30)
    except (BrokenPipeError, subprocess.TimeoutExpired):
        server.terminate()
        result["server_exit"] = server.wait(timeout=10)
    receipt.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result), flush=True)
raise SystemExit(0 if result.get("client_exit") == 0 and result.get("server_exit") == 0 else 1)
