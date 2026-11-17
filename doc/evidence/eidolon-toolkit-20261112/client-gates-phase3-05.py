"""Full sequential client gate for eidolon toolkit Phase 3 (labels phase3-client-05-*)."""
import pathlib, subprocess, sys

evidence = pathlib.Path(__file__).resolve().parent
root = evidence.parents[2]
runner = evidence / 'run-gate.py'
engine = root / 'client/_build/godot-clean/Godot_v4.7.2-stable_mono_linux_x86_64/Godot_v4.7.2-stable_mono_linux.x86_64'
private = pathlib.Path.home() / '.cache/quod-eidolon-toolkit/phase3-client-05'
label = 'phase3-client-05-'
if private.exists():
    raise SystemExit('Refusing to reuse ' + str(private))
workspace = ['env', 'M1B_PHASE=workspace', 'M1B_RESULT=' + str(private / 'workspace/result.json'),
             'M4_MODEL=' + str(root / 'priv/explorer/assets/models/bd201855c8114b9b0e9cdd465d6f08413d18604894c839fb78d54d890c2adc94.glb'),
             'M4_MAPPING=' + str(root / 'doc/evidence/godot-m4-20261029/inputs/injected-mapping.term'),
             'M4_PRESENTATION_IMAGES=' + str(private / 'workspace/images'),
             'python3', 'client/godot-tools/run.py', '--', '--headless', '--xr-mode', 'off', '--', '--qualification', '--profile', str(private / 'workspace/profile')]
# The scene check runs on the real display so the marker raster is an actual engine render.
scene = ['env', 'M1B_PHASE=scene', 'M1B_RESULT=' + str(evidence / (label + 'scene-result.json')),
         'M2_SCENE_CAPTURE=' + str(evidence / (label + 'wire.png')), 'M2_MARKER_CAPTURE=' + str(evidence / (label + 'marker.png')),
         'python3', 'client/godot-tools/run.py', '--', '--xr-mode', 'off', '--', '--qualification', '--profile', str(private / 'scene')]
steps = [
    ('javascript', ['npm', '--prefix', 'client', 'test']),
    ('core-clean', ['dotnet', 'clean', 'client/godot-tests/Quod.Client.Tests.csproj']),
    ('godot-clean', ['env', 'NUGET_PACKAGES=' + str(root / 'client/_build/godot-clean/nuget'), 'dotnet', 'clean', 'client/godot/Quod.csproj']),
    ('core', ['dotnet', 'run', '--project', 'client/godot-tests', '--', str(root)]),
    ('godot-build', ['python3', 'client/godot-tools/run.py', '--export']),
    ('package-content', [str(engine), '--headless', '--xr-mode', 'off', '--main-pack', str(root / 'client/godot/dist/quod.pck'), '--script', str(evidence / 'verify-export.gd')]),
    ('godot-icons', ['env', 'M1B_PHASE=icons', 'python3', 'client/godot-tools/run.py', '--', '--headless', '--xr-mode', 'off', '--', '--qualification', '--profile', str(private / 'icons')]),
    ('scene', scene),
    ('workspace', workspace),
    ('gui', [sys.executable, str(evidence / 'client-journey.py'), label + 'gui-journey', 'gui']),
    ('spaces', [sys.executable, str(evidence / 'client-journey.py'), label + 'spaces-journey', 'spaces']),
    ('navigation', [sys.executable, str(evidence / 'client-journey.py'), label + 'navigation-journey', 'navigation']),
    ('local-backup', ['python3', 'client/godot-tests/local.py', '--export', str(root / 'client/godot/dist/quod.x86_64'), '--phase', 'crypto', '--evidence', str(evidence / (label + 'local-backup-journey')), '--private', str(private / 'local-backup')]),
]
for name, command in steps:
    result = subprocess.run([sys.executable, str(runner), label + name, *command], cwd=root, stdout=subprocess.DEVNULL)
    print(name, 'exit', result.returncode, flush=True)
    if result.returncode:
        print('STOPPED on ' + name, flush=True)
        raise SystemExit(result.returncode)
print('PHASE3_CLIENT_05_PASS', flush=True)
