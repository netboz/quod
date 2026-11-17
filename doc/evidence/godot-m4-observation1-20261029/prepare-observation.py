#!/usr/bin/env python3
"""Retain exact driver base; adapt only private safe timeout capture/EOF receipts."""
import difflib,hashlib,json,shutil
from pathlib import Path

root=Path.cwd();ev=Path(__file__).resolve().parent
cache=Path('/home/yan/.cache/quod-m4-observation1-artifacts')
drivers=ev/'inputs/desktop-drivers';drivers.mkdir(exist_ok=False)
def h(path):return hashlib.sha256(path.read_bytes()).hexdigest()
base=root/'client/godot-tests/local.py';before=base.read_text();after=before
changes=[
 ('p = argparse.ArgumentParser()', 'os.umask(0o077)\np = argparse.ArgumentParser()'),
 ("killed = False; text = ''", "killed = False; text = ''; output_eof = False"),
 ("diagnostic=a.evidence/(label+'-shutdown-stacks.log')", "diagnostic=a.private/'shutdown-diagnostics'/(label+'-native-stacks.log')\n                diagnostic.parent.mkdir(mode=0o700,parents=True,exist_ok=False)"),
 ("with diagnostic.open('x') as trace:","with diagnostic.open('x') as trace:\n                        diagnostic.chmod(0o600)"),
 ("['gdb','-q','-batch','-p',str(child.pid),'-ex','set print frame-arguments none','-ex','set print entry-values no','-ex','thread apply all bt 16']", "['gdb','-q','-nx','-batch','-iex','set auto-load off','-iex','set debuginfod enabled off','-p',str(child.pid),'-ex','set print frame-arguments none','-ex','set print entry-values no','-ex','thread apply all bt 16','-ex','detach']"),
 ("'watchdog': True,'diagnostic':str(diagnostic)","'watchdog': True,'owned_pid':child.pid,'output_eof':False,'arguments':False,'memory_dump':False,'gdb_user_init':False,'gdb_auto_load':False,'diagnostic':str(diagnostic)"),
 ("if line is None: break", "if line is None: output_eof = True; break"),
 ("'external_sigkill_at_observed_seam': killed, 'passed': passed", "'external_sigkill_at_observed_seam': killed, 'output_eof':output_eof, 'watchdog':False, 'passed': passed")]
for old,new in changes:
    assert after.count(old)==1,old
    after=after.replace(old,new)
assert 'lines.get(timeout=60)' in after and 'timeout=15' in after
shutil.copy2(base,drivers/'local-base.py');(drivers/'local.py').write_text(after)
(drivers/'local-safety.patch').write_text(''.join(difflib.unified_diff(before.splitlines(True),after.splitlines(True),fromfile='current/local.py',tofile='diagnostic/local.py')))
shutil.copy2(root/'client/godot-tests/desktop_input.py',drivers/'desktop_input.py')
oldserve=root/'doc/evidence/godot-m4-r2-20261029/serve.py';serve=oldserve.read_text()
serve=serve.replace("evidence = root / 'doc/evidence/godot-m4-r2-20261029'","evidence = root / 'doc/evidence/godot-m4-observation1-20261029'")
serve=serve.replace('/home/yan/.cache/quod-m4-r2-artifacts/private/','/home/yan/.cache/quod-m4-observation1-artifacts/private/')
(ev/'serve.py').write_text(serve)
for name in ['godot_m3b_fixture.erl','godot_m3b_physics_fixture.erl']:
    shutil.copy2(root/'doc/evidence/godot-m4-r2-20261029'/name,ev/name)
core=Path('/home/yan/.cache/quod-m4-r2-artifacts/artifacts/quod-m4-client-final03/source/client/godot-tests/bin/Debug/net10.0')
provider=cache/'account-preparation-tool';provider.mkdir(mode=0o700,parents=True,exist_ok=False)
shutil.copy2(ev/'prepare-account.cs',provider/'Program.cs')
project='''<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><RuntimeFrameworkVersion>10.0.12</RuntimeFrameworkVersion><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup><ItemGroup>'''
for name in ['Quod.Client.Tests','BouncyCastle.Cryptography']:
    assert (core/(name+'.dll')).is_file()
    project+='<Reference Include="'+name+'"><HintPath>'+str(core/(name+'.dll'))+'</HintPath></Reference>'
project+='</ItemGroup></Project>\n'
(provider/'Prepare.csproj').write_text(project);(ev/'inputs/Prepare.csproj').write_text(project)
(provider/'NuGet.Config').write_text('<configuration><packageSources><clear/></packageSources></configuration>\n')
record={'local_base_sha256':h(base),'local_supplied_sha256':h(drivers/'local.py'),'local_changes':changes,
    'reader_exception_behavior':'Unchanged original reader. Driver stdout AND stderr are retained separately; missing child traceback does not rule out a daemon reader failure.',
    'watchdog_silence_seconds':60,'capture_timeout_seconds':15,'capture_only_after_actual_watchdog':True,
    'no_new_capture_timer_or_polling':True,'desktop_input_sha256':h(drivers/'desktop_input.py'),
    'server_base_sha256':h(oldserve),'server_supplied_sha256':h(ev/'serve.py'),'server_changes':'Evidence/private output paths only; same final03 fixture and accepted production inputs',
    'preparation':'Fresh isolated fixture account via accepted existing Accounts owner; no previous profile/store/unknown operation used',
    'preparation_source_sha256':h(ev/'prepare-account.cs'),'preparation_project_sha256':h(provider/'Prepare.csproj'),
    'accepted_preparation_core_module':{str(core/name):h(core/name) for name in ['Quod.Client.Tests.dll','BouncyCastle.Cryptography.dll']},
    'core_tests_rerun':False,'compiled_application_inputs_in_diagnostic_export':False}
(ev/'inputs/driver-preparation.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'prepared':True,'watchdog_seconds':60,'only_safety_and_eof_driver_changes':True,'provider':str(provider)}))
