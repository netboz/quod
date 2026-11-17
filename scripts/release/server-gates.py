"""Full sequential server gates: clean, eunit, ct, xref, dialyzer.

    server-gates.py <evidence-dir> <label>      for example: doc/evidence/x-20261117 server-01

Every step runs even after a failure. The last line printed is
SERVER_RESULT <label> <list of (step, exit) that failed>.
"""
import pathlib, subprocess, sys
tools = pathlib.Path(__file__).resolve().parent
root = tools.parents[1]
evidence, label = sys.argv[1:]
runner = str(tools / "run-gate.py")
steps = [("clean-default", ["rebar3", "clean", "--all"]), ("clean-test", ["rebar3", "as", "test", "clean", "--all"]),
         ("eunit", ["rebar3", "as", "test", "eunit"]), ("ct", ["rebar3", "as", "test", "ct"]),
         ("xref", ["rebar3", "xref"]), ("dialyzer", ["rebar3", "dialyzer"])]
failures = []
for name, command in steps:
    result = subprocess.run([sys.executable, runner, evidence, label + "-" + name, *command], cwd=root, stdout=subprocess.DEVNULL)
    if result.returncode:
        failures.append((name, result.returncode))
print("SERVER_RESULT " + label + " " + repr(failures), flush=True)
sys.exit(1 if failures else 0)
