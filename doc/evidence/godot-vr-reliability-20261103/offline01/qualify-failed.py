"""Finite offline checks of the saved companion and its actual supervisor."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

E = Path(__file__).resolve().parent
ROOT = E.parents[2]
OWNER = E.parent / 'godot-vr-visual-readiness-20261102'
COMPANION = E.parent / 'godot-visibility-test-20261103'
parser = argparse.ArgumentParser()
parser.add_argument('label')
args = parser.parse_args()
out = E / args.label
out.mkdir(exist_ok=False)
inputs = out / 'inputs'
inputs.mkdir()
stage = Path(tempfile.mkdtemp(prefix='quod-vr-reliability-'))
record = {'passed': False, 'software_only': True, 'stage': str(stage), 'inputs': {}, 'commands': []}

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def save():
    (out / 'result.json').write_text(json.dumps(record, indent=2) + '\n')

def copy(path):
    target = inputs / path.name
    assert not target.exists(), target
    shutil.copy2(path, target)
    record['inputs'][str(path.relative_to(ROOT))] = digest(target)
    return target

env = dict(os.environ)
for name in ['LD_LIBRARY_PATH', 'LD_PRELOAD']:
    env.pop(name, None)
env.update(DOTNET_CLI_HOME=str(stage / 'dotnet-home'), DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1',
           DOTNET_CLI_TELEMETRY_OPTOUT='1', NUGET_PACKAGES=str(stage / 'nuget'), PYTHONDONTWRITEBYTECODE='1')

def run(name, argv, cwd):
    row = {'name': name, 'argv': argv, 'cwd': str(cwd), 'timeout_seconds': 60}
    record['commands'].append(row)
    save()
    start = time.monotonic()
    with (out / (name + '.log')).open('xb') as log:
        child = subprocess.Popen(argv, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            row['true_exit'] = child.wait(timeout=60)
        except subprocess.TimeoutExpired:
            row['timed_out'] = True
            child.kill()  # this newly created offline check only
            row['true_exit'] = child.wait()
    row['elapsed_seconds'] = time.monotonic() - start
    save()
    print(json.dumps(row), flush=True)
    assert row['true_exit'] == 0 and not row.get('timed_out'), name

try:
    manifest_path = COMPANION / 'inputs/client-visibility-visual-companion04-manifest.json'
    manifest = json.loads(copy(manifest_path).read_text())
    source = Path(manifest['stage']) / 'source'
    assert manifest['passed'] and not manifest['distributable']
    assert len(manifest['live_source_inputs']) == 98 and len(manifest['export_outputs']) == 196
    assert all(row['true_exit'] == 0 for row in manifest['commands'])
    assert all(digest(ROOT / path) == sha for path, sha in manifest['live_source_inputs'].items())
    assert all(digest(source / path) == sha for path, sha in manifest['supplied_inputs'].items())
    for name in ['VrFrameReady.cs', 'FrameObservation.cs']:
        assert digest(COMPANION / name) == manifest['supplied_inputs']['client/godot/tests/' + name]
        copy(COMPANION / name)
    for name in ['Quod.dll', 'Quod.pdb', 'Quod.runtimeconfig.json', 'Quod.deps.json']:
        path = 'data_Quod_linuxbsd_x86_64/' + name
        assert digest(Path(manifest['export_executable']).parent / path) == manifest['export_outputs'][path]['sha256']
    record['binding'] = {'manifest_sha256': digest(manifest_path), 'live_inputs': 98,
        'supplied_inputs': len(manifest['supplied_inputs']), 'saved_build_phase_exits': [r['true_exit'] for r in manifest['commands']],
        'managed_export_files_verified': 4, 'full_native_export_reaudit': False}
    for name in ['live.py', 'supervision.py', 'owned_commands.py', 'pipe_ownership.py',
                 'test_supervision.py', 'test_owned_commands.py', 'FrameObservationChecks.cs', 'closure281.json']:
        copy(OWNER / name)
    for name in ['check_live.py', 'AdmissionChecks.cs', 'qualify.py']:
        copy(E / name)
    copy(COMPANION / 'attempt-visual02-result.json')
    text = (inputs / 'VrFrameReady.cs').read_text()
    assert 'visualReady.Task.WaitAsync(admissionStop.Token)' in text
    assert 'TimeSpan.FromSeconds(30)' not in text
    block = text[text.index('        RenderingServer.FramePostDraw+=Observe;'):text.rindex('\n    }\n}')]
    finish = next(line for line in text.splitlines() if 'static bool Finish(' in line)
    generated = 'using System.Text.Json;\ninternal sealed partial class AdmissionCase {\npublic async Task Run() {\n' + finish + '\n' + block + '\n}\n}\n'
    (inputs / 'AdmissionBody.cs').write_text(generated)
    for name in ['AdmissionBody.cs', 'AdmissionChecks.cs', 'FrameObservation.cs']:
        shutil.copy2(inputs / name, stage / name)
    (stage / 'Program.cs').write_text((inputs / 'FrameObservationChecks.cs').read_text() + '\nawait AdmissionChecks.Run();\n')
    (stage / 'Offline.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup></Project>\n')
    (stage / 'NuGet.Config').write_text('<configuration><packageSources><clear/></packageSources></configuration>\n')
    shutil.copy2(ROOT / 'client/godot/global.json', stage / 'global.json')
    for name in ['Program.cs', 'Offline.csproj', 'NuGet.Config', 'global.json']:
        shutil.copy2(stage / name, inputs / name)
    run('build', ['dotnet', 'build', 'Offline.csproj', '--disable-build-servers', '-p:UseSharedCompilation=false', '--configfile', 'NuGet.Config'], stage)
    run('admission', ['dotnet', str(stage / 'bin/Debug/net10.0/Offline.dll')], stage)
    run('supervision', [sys.executable, '-B', str(OWNER / 'test_supervision.py')], ROOT)
    run('owned-pipes', [sys.executable, '-B', str(OWNER / 'test_owned_commands.py')], ROOT)
    run('live-loop', [sys.executable, '-B', str(E / 'check_live.py')], ROOT)
    assert all(digest(ROOT / name) == sha for name, sha in record['inputs'].items())
    record['passed'] = True
finally:
    save()
