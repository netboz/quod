import pathlib, subprocess, sys
root = pathlib.Path(__file__).resolve().parents[3]
runner = str(pathlib.Path(__file__).with_name("run-gate.py"))
steps = [
 ("client-final-01-javascript", ["npm", "--prefix", "client", "test"]),
 ("client-final-01-core-clean", ["dotnet", "clean", "client/godot-tests/Quod.Client.Tests.csproj"]),
 ("client-final-01-godot-clean", ["env", "NUGET_PACKAGES=" + str(root / "client/_build/godot-clean/nuget"), "dotnet", "clean", "client/godot/Quod.csproj"]),
 ("client-final-01-core", ["dotnet", "run", "--project", "client/godot-tests", "--", str(root)]),
 ("client-final-01-godot-build", ["python3", "client/godot-tools/run.py", "--export"]),
 ("client-final-01-godot-icons", ["env", "M1B_PHASE=icons", "python3", "client/godot-tools/run.py", "--", "--headless", "--xr-mode", "off", "--", "--qualification", "--profile", "/tmp/quod-phase1-icons-gate-final-01-20261109"]),
 ("client-final-01-gui", [sys.executable, str(pathlib.Path(__file__).with_name("client-journey.py")), "client-final-01-gui-journey", "gui"]),
 ("client-final-01-spaces", [sys.executable, str(pathlib.Path(__file__).with_name("client-journey.py")), "client-final-01-spaces-journey", "spaces"]),
 ("client-final-01-navigation", [sys.executable, str(pathlib.Path(__file__).with_name("client-journey.py")), "client-final-01-navigation-journey", "navigation"]),
]
steps.append(("client-final-01-local-backup", ["python3", "client/godot-tests/local.py", "--export", str(root / "client/godot/dist/quod.x86_64"), "--phase", "crypto", "--evidence", str(root / "doc/evidence/ontology-references-phase1-20261109/client-final-01-local-backup-journey"), "--private", "/tmp/pearl-phase1-local-backup-final-01"]))
for name, command in steps:
    result = subprocess.run([sys.executable, runner, name, *command], cwd=root)
    if result.returncode:
        print("STOPPED on " + name, flush=True)
        sys.exit(result.returncode)
print("GODOT_CLIENT_GATES_PASS", flush=True)
