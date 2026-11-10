import pathlib, subprocess, sys
root = pathlib.Path(__file__).resolve().parents[3]
runner = str(pathlib.Path(__file__).with_name("run-gate.py"))
steps = [
 ("postphase-client-01-javascript", ["npm", "--prefix", "client", "test"]),
 ("postphase-client-01-core-clean", ["dotnet", "clean", "client/godot-tests/Quod.Client.Tests.csproj"]),
 ("postphase-client-01-godot-clean", ["env", "NUGET_PACKAGES=" + str(root / "client/_build/godot-clean/nuget"), "dotnet", "clean", "client/godot/Quod.csproj"]),
 ("postphase-client-01-core", ["dotnet", "run", "--project", "client/godot-tests", "--", str(root)]),
 ("postphase-client-01-godot-build", ["python3", "client/godot-tools/run.py", "--export"]),
 ("postphase-client-01-package-content", [str(root / "client/_build/godot-clean/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64"), "--headless", "--xr-mode", "off", "--main-pack", str(root / "client/godot/dist/quod.pck"), "--script", str(pathlib.Path(__file__).with_name("verify-export.gd"))]),
 ("postphase-client-01-godot-icons", ["env", "M1B_PHASE=icons", "python3", "client/godot-tools/run.py", "--", "--headless", "--xr-mode", "off", "--", "--qualification", "--profile", "/tmp/quod-postphase-icons-gate-01-20261110"]),
 ("postphase-client-01-gui", [sys.executable, str(pathlib.Path(__file__).with_name("client-journey.py")), "postphase-client-01-gui-journey", "gui"]),
 ("postphase-client-01-spaces", [sys.executable, str(pathlib.Path(__file__).with_name("client-journey.py")), "postphase-client-01-spaces-journey", "spaces"]),
 ("postphase-client-01-navigation", [sys.executable, str(pathlib.Path(__file__).with_name("client-journey.py")), "postphase-client-01-navigation-journey", "navigation"]),
]
steps.append(("postphase-client-01-local-backup", ["python3", "client/godot-tests/local.py", "--export", str(root / "client/godot/dist/quod.x86_64"), "--phase", "crypto", "--evidence", str(root / "doc/evidence/ontology-references-phase2-20261110/postphase-client-01-local-backup-journey"), "--private", "/tmp/pearl-postphase-local-backup-01"]))
for name, command in steps:
    result = subprocess.run([sys.executable, runner, name, *command], cwd=root)
    if result.returncode:
        print("STOPPED on " + name, flush=True)
        sys.exit(result.returncode)
print("GODOT_CLIENT_GATES_PASS", flush=True)
