import pathlib, subprocess, sys
root = pathlib.Path(__file__).resolve().parents[3]
runner = str(pathlib.Path(__file__).with_name("run-gate.py"))
steps = [
 ("client-01-javascript", ["npm", "--prefix", "client", "test"]),
 ("client-01-core-clean", ["dotnet", "clean", "client/godot-tests/Quod.Client.Tests.csproj"]),
 ("client-01-godot-clean", ["env", "NUGET_PACKAGES=" + str(root / "client/_build/godot-clean/nuget"), "dotnet", "clean", "client/godot/Quod.csproj"]),
 ("client-01-core", ["dotnet", "run", "--project", "client/godot-tests", "--", str(root)]),
 ("client-01-godot-build", ["python3", "client/godot-tools/run.py", "--export"]),
 ("client-01-godot-icons", ["env", "M1B_PHASE=icons", "python3", "client/godot-tools/run.py", "--", "--headless", "--xr-mode", "off", "--", "--qualification", "--profile", "/tmp/quod-phase1-icons-gate-01-20261109"]),
 ("client-01-gui", [sys.executable, str(pathlib.Path(__file__).with_name("client-journey.py")), "client-01-gui-journey", "gui"]),
 ("client-01-spaces", [sys.executable, str(pathlib.Path(__file__).with_name("client-journey.py")), "client-01-spaces-journey", "spaces"]),
 ("client-01-navigation", [sys.executable, str(pathlib.Path(__file__).with_name("client-journey.py")), "client-01-navigation-journey", "navigation"]),
]
for name, command in steps:
    result = subprocess.run([sys.executable, runner, name, *command], cwd=root)
    if result.returncode:
        print("STOPPED on " + name, flush=True)
        sys.exit(result.returncode)
print("GODOT_CLIENT_GATES_PASS", flush=True)
