"""Full sequential client gate for the form-lifecycle change (labels formlife02-*)."""
import pathlib, subprocess, sys

root = pathlib.Path(__file__).resolve().parents[3]
evidence = root / 'doc/evidence/ontology-references-phase2-20261110'
runner = evidence / 'run-gate.py'
engine = root / 'client/_build/godot-clean/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64'
private = pathlib.Path('/tmp/quod-formlife02')
workspace = ['env', 'M1B_PHASE=workspace', 'M1B_RESULT=' + str(private / 'workspace/result.json'),
             'M4_MODEL=' + str(root / 'priv/explorer/assets/models/bd201855c8114b9b0e9cdd465d6f08413d18604894c839fb78d54d890c2adc94.glb'),
             'M4_MAPPING=' + str(root / 'doc/evidence/godot-m4-20261029/inputs/injected-mapping.term'),
             'M4_PRESENTATION_IMAGES=' + str(private / 'workspace/images'),
             'python3', 'client/godot-tools/run.py', '--', '--headless', '--xr-mode', 'off', '--', '--qualification', '--profile', str(private / 'workspace/profile')]
steps = [
    ('formlife02-javascript', ['npm', '--prefix', 'client', 'test']),
    ('formlife02-core-clean', ['dotnet', 'clean', 'client/godot-tests/Quod.Client.Tests.csproj']),
    ('formlife02-godot-clean', ['env', 'NUGET_PACKAGES=' + str(root / 'client/_build/godot-clean/nuget'), 'dotnet', 'clean', 'client/godot/Quod.csproj']),
    ('formlife02-core', ['dotnet', 'run', '--project', 'client/godot-tests', '--', str(root)]),
    ('formlife02-godot-build', ['python3', 'client/godot-tools/run.py', '--export']),
    ('formlife02-package-content', [str(engine), '--headless', '--xr-mode', 'off', '--main-pack', str(root / 'client/godot/dist/quod.pck'), '--script', str(evidence / 'verify-export.gd')]),
    ('formlife02-godot-icons', ['env', 'M1B_PHASE=icons', 'python3', 'client/godot-tools/run.py', '--', '--headless', '--xr-mode', 'off', '--', '--qualification', '--profile', str(private / 'icons')]),
    ('formlife02-workspace', workspace),
    ('formlife02-gui', [sys.executable, str(evidence / 'client-journey.py'), 'formlife02-gui-journey', 'gui']),
    ('formlife02-spaces', [sys.executable, str(evidence / 'client-journey.py'), 'formlife02-spaces-journey', 'spaces']),
    ('formlife02-navigation', [sys.executable, str(evidence / 'client-journey.py'), 'formlife02-navigation-journey', 'navigation']),
    ('formlife02-local-backup', ['python3', 'client/godot-tests/local.py', '--export', str(root / 'client/godot/dist/quod.x86_64'), '--phase', 'crypto', '--evidence', str(evidence / 'formlife02-local-backup-journey'), '--private', str(private / 'local-backup')]),
]
for name, command in steps:
    result = subprocess.run([sys.executable, str(runner), name, *command], cwd=root, stdout=subprocess.DEVNULL)
    print(name, 'exit', result.returncode, flush=True)
    if result.returncode:
        print('STOPPED on ' + name, flush=True)
        raise SystemExit(result.returncode)
print('FORMLIFE02_CLIENT_PASS', flush=True)
