"""Run one gate step and keep its log and exit.

    run-gate.py <evidence-dir> <label> <command...>

The log is <evidence-dir>/<label>.log and one line is added to
<evidence-dir>/results.jsonl. An existing log is never overwritten.
"""
import datetime, json, pathlib, subprocess, sys
root = pathlib.Path(__file__).resolve().parents[2]
evidence = pathlib.Path(sys.argv[1]).resolve()
name, *command = sys.argv[2:]
evidence.mkdir(parents=True, exist_ok=True)
log = evidence / (name + ".log")
if log.exists():
    raise SystemExit("Refusing to overwrite gate evidence: " + str(log))
started = datetime.datetime.now(datetime.timezone.utc).isoformat()
with log.open("xb") as output:
    child = subprocess.run(command, cwd=root, stdout=output, stderr=subprocess.STDOUT)
result = {"name": name, "command": command, "started": started, "ended": datetime.datetime.now(datetime.timezone.utc).isoformat(), "exit_code": child.returncode, "log": str(log)}
with (evidence / "results.jsonl").open("a") as output:
    output.write(json.dumps(result) + "\n")
print(json.dumps(result), flush=True)
print(log.read_text(errors="replace")[-5000:], flush=True)
sys.exit(child.returncode)
