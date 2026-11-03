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


parent = (E / 'inputs/VrFrameReady-before.cs').read_text()
current = (E / 'VrFrameReady.cs').read_text()
def block(text, start, end):
    return text[text.index(start):text.index(end,text.index(start))]
check(block(current,'            bool usable=','            if(usable') ==
      block(parent,'            bool usable=','            if(usable'),
      'strict two supported tracked neutral controllers and signed input predicate is byte-identical')
check(block(current,'            bool frame=','            previous=') ==
      block(parent,'            bool frame=','            previous='),
      'compound stereo render predicate remains byte-identical')
check(current[:current.index('        var xr=')] == parent[:parent.index('        var xr=')],
      'all preparation/domain setup and begin behavior remains byte-identical')
check('long previous=api.GetPredictedDisplayTime();' in current,
      'first rendered callback compares against an actual preceding native-time sample')
check('var admission=visualReady.Task.WaitAsync(TimeSpan.FromSeconds(30),admissionStop.Token);' in current and
      'ready.Task.WaitAsync' not in current,
      'finite no-visual-frame failure bound awaits only visual readiness')
check('Report("VR263_VISUAL_READY",Snapshot("visual"));visualReady.TrySetResult();' in current and
      'if(usable&&!admitted){admitted=true;Report("VR263_READY",Snapshot("interaction"));}' in current,
      'visual event is immediate and strict interaction event is separate with no second wait')
check('State["world_accepted"]?.GetValue<bool>()==true,State["question_receiver_ready"]?.GetValue<bool>()==true,!session.IsExpired' in current,
      'current signed world receiver and original unexpired sign-in gate visual admission')
check(current.count('RenderingServer.FramePostDraw+=Observe;')==1 and current.count('RenderingServer.FramePostDraw-=Observe;')==2,
      'existing notification and both cleanup unsubscribe paths remain')
check('if(visualAdmitted&&state!=last)' in current,
      'after visual admission controller and authorization state changes remain observable')
old_supervisor=(E/'inputs/supervision-before.py').read_text()
expected=old_supervisor.replace("if name=='VR263_BLOCKER':self.stop('native_admission_failure',now)","if name=='VR263_BLOCKER':self.stop('visual_admission_failure',now)").replace("first=name=='VR263_READY'","first=name=='VR263_VISUAL_READY'")
check((E/'supervision.py').read_text()==expected,
      'supervision delta is only visual admission marker and truthful failure label; timers/expiry/finish fences unchanged')
for name in ['owned_commands.py','pipe_ownership.py','launch_spec.py']:
    check((E/name).read_bytes()==(OLD/name).read_bytes(),'unchanged real owner '+name)
contract=json.loads((E/'future-stop-contract.json').read_text())
check(contract['sequence'][1]['stdin'].encode()==bytes.fromhex('73746f700a') and
      contract['sequence'][0]['stdin'].encode()==bytes.fromhex('66696e6973680a'),
      'distinct literal client finish and fixture stop bytes retained')
fixture=(OLD/'godot_m3b_fixture.erl').read_text()
check('"stop\\n" -> ok;' in fixture and 'json:decode(list_to_binary(Line))' in fixture,
      'actual fixture command owner accepts stop-LF; a blank line is not its stop branch')
import ast
card=json.loads((E/'run-card.json').read_text())
def actual_parser(path,argv):
    nodes=[]
    for node in ast.parse(path.read_text()).body:
        if isinstance(node,ast.Assign) and isinstance(node.value,ast.Call) and isinstance(node.value.func,ast.Attribute) and isinstance(node.value.func.value,ast.Name) and node.value.func.value.id=='argparse' and node.value.func.attr=='ArgumentParser':
            nodes.append(node)
        elif isinstance(node,ast.Expr) and isinstance(node.value,ast.Call) and isinstance(node.value.func,ast.Attribute) and isinstance(node.value.func.value,ast.Name) and node.value.func.value.id=='p' and node.value.func.attr=='add_argument':
            nodes.append(node)
    assert nodes
    scope={'argparse':argparse,'Path':Path}
    exec(compile(ast.Module(body=nodes,type_ignores=[]),str(path),'exec'),scope)
    return scope['p'].parse_args(argv)
fargs=card['fixture']['argv'];cargs=card['client']['argv']
f=actual_parser(OLD/'manual_run.py',fargs[3:]);s=actual_parser(OLD/'serve.py',fargs[8:]);c=actual_parser(E/'live.py',cargs[3:])
check(f.label=='attention-visual-fixture-wrapper01' and s.label==c.server_label=='attention-visual-human01-server' and c.label=='attention-visual-human01',
      'exact run-card argv passes the actual three owner parsers without executing their launch bodies')
check(s.qualified and s.presentation_source and s.profile=='test' and c.launch_and_begin and
      str(c.manifest).endswith('client-attention-vr-visual-companion01-manifest.json'),
      'future argv selects current server contract and locally delegated new companion')
check(card['fixture']['tty'] is True and card['client']['tty'] is True and not card['launch_authorized'],
      'both future commands require tty:true and this artifact grants no launch')
record = {'source_checks': checks, 'stage': str(stage), 'inputs': {}, 'commands': [],
          'app_fixture_runtime_started': False}
for name in ['FrameObservation.cs', 'FrameObservationChecks.cs', 'VrFrameReady.cs', 'live.py', 'supervision.py', 'owned_commands.py', 'pipe_ownership.py', 'launch_spec.py', 'test_supervision.py', 'test_owned_commands.py', 'test_launch_spec.py', 'run-card.json']:
    source = E / name
    target = stage / name
    shutil.copy2(source, target)
    record['inputs'][name] = {'source': str(source), 'copy': str(target),
                             'sha256': hashlib.sha256(target.read_bytes()).hexdigest()}
shutil.copy2(E.parent/'godot-vr-frame-observation-20261102/closure281.json',stage/'closure281.json')
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
    ('checks', ['dotnet', 'exec', 'bin/Release/net10.0/OfflineChecks.dll']),
    ('supervision', [sys.executable, '-B', 'test_supervision.py']),
    ('owned-commands', [sys.executable, '-B', 'test_owned_commands.py']),
    ('literal-arguments', [sys.executable, '-B', 'test_launch_spec.py'])
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
print('VISUAL_OFFLINE_COMPLETE ' + json.dumps({'source_checks': checks,
    'build_exit': 0, 'check_exit': 0, 'native_runtime_started': False}))
