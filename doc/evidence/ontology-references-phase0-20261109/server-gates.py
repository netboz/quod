import pathlib, subprocess, sys
root = pathlib.Path(__file__).resolve().parents[3]
runner = str(pathlib.Path(__file__).with_name("run-gate.py"))
steps = [
 ("clean-default", ["rebar3", "clean", "--all"]),
 ("clean-test", ["rebar3", "as", "test", "clean", "--all"]),
 ("native", ["cargo", "test", "--locked", "--manifest-path", "native/quod_physics/Cargo.toml"]),
 ("eunit", ["rebar3", "as", "test", "eunit"]),
 ("ct", ["rebar3", "as", "test", "ct"]),
 ("xref", ["rebar3", "xref"]),
 ("dialyzer", ["rebar3", "dialyzer"]),
]
for name, command in steps:
    result = subprocess.run([sys.executable, runner, name, *command], cwd=root)
    if result.returncode:
        print("STOPPED on " + name, flush=True)
        sys.exit(result.returncode)
print("SERVER_GATES_PASS", flush=True)
