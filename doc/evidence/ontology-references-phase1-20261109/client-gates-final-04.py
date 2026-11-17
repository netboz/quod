import pathlib, subprocess, sys
root = pathlib.Path(__file__).resolve().parents[3]
runner = str(pathlib.Path(__file__).with_name("run-gate.py"))
steps = [
 ("client-final-04-javascript", ["npm", "--prefix", "client", "test"]),
 ("client-final-04-core-clean", ["dotnet", "clean", "client/godot-tests/Quod.Client.Tests.csproj"]),
 ("client-final-04-godot-clean", ["env", "NUGET_PACKAGES=" + str(root / "client/_build/godot-clean/nuget"), "dotnet", "clean", "client/godot/Quod.csproj"]),
 ("client-final-04-core", ["dotnet", "run", "--project", "client/godot-tests", "--", str(root)]),
 ("client-final-04-godot-build", ["python3", "client/godot-tools/run.py", "--export"]),
 ("client-final-04-package-content", [str(root / "client/_build/godot-clean/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64"), "--headless", "--xr-mode", "off", "--main-pack", str(root / "client/godot/dist/quod.pck"), "--script", str(pathlib.Path(__file__).with_name("verify-export.gd"))]),
 ("client-final-04-godot-icons", ["env", "M1B_PHASE=icons", "python3", "client/godot-tools/run.py", "--", "--headless", "--xr-mode", "off", "--", "--qualification", "--profile", "/tmp/quod-phase1-icons-gate-final-04-20261109"]),
 ("client-final-04-gui", [sys.executable, str(pathlib.Path(__file__).with_name("client-journey.py")), "client-final-04-gui-journey", "gui"]),
 ("client-final-04-spaces", [sys.executable, str(pathlib.Path(__file__).with_name("client-journey.py")), "client-final-04-spaces-journey", "spaces"]),
 ("client-final-04-navigation", [sys.executable, str(pathlib.Path(__file__).with_name("client-journey.py")), "client-final-04-navigation-journey", "navigation"]),
]
steps.append(("client-final-04-local-backup", ["python3", "client/godot-tests/local.py", "--export", str(root / "client/godot/dist/quod.x86_64"), "--phase", "crypto", "--evidence", str(root / "doc/evidence/ontology-references-phase1-20261109/client-final-04-local-backup-journey"), "--private", "/tmp/pearl-phase1-local-backup-final-04"]))
for name, command in steps:
    result = subprocess.run([sys.executable, runner, name, *command], cwd=root)
    if result.returncode:
        print("STOPPED on " + name, flush=True)
        sys.exit(result.returncode)
print("GODOT_CLIENT_GATES_PASS", flush=True)
