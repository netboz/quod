import pathlib, subprocess, sys
root = pathlib.Path(__file__).resolve().parents[3]
runner = str(pathlib.Path(__file__).with_name("run-gate.py"))
steps = [
 ("client-core-clean", ["dotnet", "clean", "client/godot-tests/Quod.Client.Tests.csproj"]),
 ("client-godot-clean", ["env", "NUGET_PACKAGES=" + str(root / "client/_build/godot-clean/nuget"), "dotnet", "clean", "client/godot/Quod.csproj"]),
 ("client-core", ["dotnet", "run", "--project", "client/godot-tests", "--", str(root)]),
 ("client-godot-build", ["python3", "client/godot-tools/run.py", "--build"]),
 ("client-godot-icons", ["env", "M1B_PHASE=icons", "python3", "client/godot-tools/run.py", "--", "--headless", "--xr-mode", "off", "--", "--qualification", "--profile", "/tmp/quod-phase0-icons-gate-20261109"]),
]
for name, command in steps:
    result = subprocess.run([sys.executable, runner, name, *command], cwd=root)
    if result.returncode:
        print("STOPPED on " + name, flush=True)
        sys.exit(result.returncode)
print("GODOT_CLIENT_GATES_PASS", flush=True)
