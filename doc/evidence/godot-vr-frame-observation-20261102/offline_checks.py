"""Compile/check the actual diagnostic accumulator without Godot or a fixture."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

E = Path(__file__).resolve().parent
OLD = E.parent / 'godot-attention-vr-preparation-20261102'
TASK = Path('/data/quod-m4-vr-ca84d4f8-20261029')
sys.path.insert(0, str(E.parent / 'godot-m4-vive-physical-20261029'))
from environment import environment
from hashes import Digests, key

os.umask(0o077)
parser = argparse.ArgumentParser()
parser.add_argument('label')
label = parser.parse_args().label
stage = TASK / 'builds' / label
stage.mkdir(mode=0o700, exist_ok=False)
checks = 0


def check(value, label):
    global checks
    assert value, label
    checks += 1
    print('PASS ' + label, flush=True)


parent = (OLD / 'VrReady280.cs').read_bytes()
check(hashlib.sha256(parent).hexdigest() ==
      '9ea98c4911a1aafddc29909d002ca5f25c732b72cffbe9289361c120be1e2095',
      'exact closed280 observer retained')
current = (E / 'VrFrameReady.cs').read_text()
normalized = current.replace('async Task VrFrameReady()', 'async Task VrReady280()', 1)
additions = [
    '\n        var observation=new FrameObservation(System.Diagnostics.Stopwatch.Frequency);',
    '\n        long observationStarted=System.Diagnostics.Stopwatch.GetTimestamp();',
    'frame_observation=observation.Snapshot(),',
    '\n            observation.Record(now,api.CanRender(),xr?.GetSessionState().ToString()??"Unavailable",System.Diagnostics.Stopwatch.GetTimestamp()-observationStarted);'
]
for addition in additions:
    check(normalized.count(addition) == 1, 'one diagnostic insertion: ' + addition.strip().split('(')[0])
    normalized = normalized.replace(addition, '', 1)
check(normalized.encode() == parent,
      'removing observation additions reproduces exact original bootstrap readiness predicates deadline and cleanup')
check(current.count('RenderingServer.FramePostDraw+=Observe;') == 1,
      'uses the one existing notification subscription')
check(current.count('RenderingServer.FramePostDraw-=Observe;') == 2,
      'existing early-stop and final unsubscribe paths preserved')
check('TimeSpan.FromSeconds(30)' in current and 'previous=now;if(frame)rendered++;' in current,
      'original native bound and compound rendered counter unchanged')
contract = json.loads((E / 'future-stop-contract.json').read_text())
check(contract['sequence'][1]['stdin'].encode() == bytes.fromhex('73746f700a'),
      'fixture stop is literal stop plus LF')
check(contract['sequence'][0]['stdin'].encode() == bytes.fromhex('66696e6973680a') and
      not contract['launch_authorized'], 'client finish remains separate and preparation grants no launch')
record = {'source_checks': checks, 'stage': str(stage), 'inputs': {}, 'commands': [],
          'app_fixture_runtime_started': False}
for name in ['FrameObservation.cs', 'FrameObservationChecks.cs', 'VrFrameReady.cs']:
    source = E / name
    target = stage / name
    shutil.copy2(source, target)
    record['inputs'][name] = {'source': str(source), 'copy': str(target),
                             'sha256': hashlib.sha256(target.read_bytes()).hexdigest()}
manifest = json.loads((OLD / 'inputs/client-attention-vr-companion01-manifest.json').read_text())
digests = Digests()
feed = stage / 'dependency-feed'
feed.mkdir()
record['dependency_archives'] = manifest['dependency_archives']
for name, row in manifest['dependency_archives'].items():
    archive = Path(row['referenced_path'])
    assert digests.values[key(archive)] == row['sha256'], str(archive)
    (feed / name).symlink_to(archive)
(stage / 'NuGet.Config').write_text('<configuration><packageSources><clear/><add key="qualified" value="'+str(feed)+'"/></packageSources></configuration>\n')
(stage / 'OfflineChecks.csproj').write_text('''<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
  </PropertyGroup>
  <ItemGroup><Compile Include="FrameObservation.cs"/><Compile Include="FrameObservationChecks.cs"/></ItemGroup>
</Project>
''')
env = environment()
env['NUGET_PACKAGES'] = str(stage / 'nuget')
output = E / 'inputs' / (label + '.json')
for phase, argv in [
    ('build', ['dotnet', 'build', 'OfflineChecks.csproj', '-c', 'Release', '--configfile', 'NuGet.Config']),
    ('checks', ['dotnet', 'exec', 'bin/Release/net10.0/OfflineChecks.dll'])
]:
    row = {'phase': phase, 'argv': argv, 'cwd': str(stage)}
    record['commands'].append(row)
    output.write_text(json.dumps(record, indent=2) + '\n')
    result = subprocess.run(argv, cwd=stage, env=env, check=False)
    row['true_exit'] = result.returncode
    output.write_text(json.dumps(record, indent=2) + '\n')
    assert result.returncode == 0, phase
record['passed'] = True
output.write_text(json.dumps(record, indent=2) + '\n')
print('FRAME_OFFLINE_COMPLETE ' + json.dumps({'source_checks': checks,
    'build_exit': 0, 'check_exit': 0, 'native_runtime_started': False}))
