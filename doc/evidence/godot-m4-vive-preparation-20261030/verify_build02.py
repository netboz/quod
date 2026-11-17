"""Check the offline build bytes and true receipts without running the payload."""
import difflib,json,os,re,sys
sys.dont_write_bytecode=True
from pathlib import Path
from cache import Digests,TASK,raw
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests();h=d.h
completed=TASK/'cache/physical-preparation01-build-verification-hashes.json'
assert raw(completed)=='058d4d4e17f3e2a71020af61c5a9a4ddc7c8cab17cc3f8e5ff07697cac50f3af'
for row in json.loads(completed.read_text())['records']:
 k=tuple(row['stat_key']);assert k not in d.values or d.values[k]==row['sha256'];d.values[k]=row['sha256']
def load(p):return json.loads(Path(p).read_text())
base_path=root/'doc/evidence/godot-m4-presentation-20261030/inputs/client-presentation-final02-manifest.json'
assert h(base_path)=='7abf72a2c42027e889a8df268e1edbcdb2f90e3622bdf023e1e5c84824ae4ff2'
base=load(base_path);m=load(ev/'inputs/client-physical-preparation01-manifest.json');stage=Path(m['stage']);source=stage/'source'
assert m['passed'] and not m['distributable'] and not m['compiled_application_inputs_copied']
assert m['functional_application_executed'] is False and m['native_runtime_started'] is False
assert m['live_source_inputs']==base['supplied_inputs'] and len(m['supplied_inputs'])==93
added=set(m['supplied_inputs'])-set(base['supplied_inputs']);assert added=={'client/godot/tests/PhysicalChecks.cs'}
changed={n for n,v in base['supplied_inputs'].items() if m['supplied_inputs'][n]!=v}
assert changed==set(m['diagnostic_overrides'])=={'client/godot/tests/ExportChecks.cs'}
for n,v in base['supplied_inputs'].items():assert h(root/n)==v,n
for n,v in m['supplied_inputs'].items():
 assert h(source/n)==v,n
 assert not n.endswith(('.dll','.pck','.exe','.so','.pyc')),n
n='client/godot/tests/ExportChecks.cs';before=(root/n).read_text();after=(source/n).read_text()
needle='if (phase == "physics") { await PhysicsJourney(); return; }'
assert after==before.replace(needle,needle+'\n            if (phase == "vive-physical") { await VivePhysical(); return; }')
assert after.count('phase == "vive-physical"')==after.count('phase == "presentation"')==1
(ev/'inputs/staged-dispatch.patch').write_text(''.join(difflib.unified_diff(before.splitlines(True),after.splitlines(True),fromfile='accepted92/'+n,tofile='diagnostic93/'+n)))
n='client/godot/tests/PhysicalChecks.cs';physical=root/'doc/evidence/godot-m4-vive-charged-20261029/PhysicalChecks.cs'
assert h(physical)==h(source/n)=='dea82a9dec22e51de3ee67b9ccb18b5e6ca4b6f5c5aee000422c14acb2304898'
assert m['dependency_archives']==base['dependency_archives'] and m['engine_archives']==base['engine_archives']
for name,r in m['dependency_archives'].items():
 p=Path(r['referenced_path']);q=stage/'dependency-feed'/name
 assert h(p)==r['sha256'] and p.stat().st_size==r['bytes']
 assert q.is_symlink() and q.resolve()==p.resolve()
assert m['verified_cold_restore']==base['verified_cold_restore']
assert m['template']==base['template'];assert h(m['template']['path'])==m['template']['sha256']
expected_phases=['toolchain','bootstrap','restore-debug','restore-exportrelease','export']
assert [r['phase'] for r in m['commands']]==expected_phases
commands=[]
for row in m['commands']:
 result=load(ev/('client-physical-preparation01-'+row['phase'])/'result.json')
 assert row['wrapper_exit']==result['exit']==0 and not result['diagnostic_failure']
 assert result['command']==row['command']
 assert row['command']==(['dotnet','--info'] if row['phase']=='toolchain' else
  ['python3','client/godot-tools/run.py','--bootstrap'] if row['phase']=='bootstrap' else
  ['python3','client/godot-tools/run.py','--export'] if row['phase']=='export' else
  ['dotnet','restore','Quod.csproj','--locked-mode','-p:Configuration='+('Debug' if row['phase']=='restore-debug' else 'ExportRelease'),'-p:SelfContained=true','--source',str(stage/'dependency-feed')])
 commands.append({'phase':row['phase'],'true_exit':result['exit'],'log_sha256':h(ev/('client-physical-preparation01-'+row['phase'])/'output.log')})
outputs={str(p.relative_to(source/'client/godot/dist')):p for p in (source/'client/godot/dist').rglob('*') if p.is_file()}
assert set(outputs)==set(m['export_outputs']) and len(outputs)==196
for n,p in outputs.items():assert h(p)==m['export_outputs'][n]['sha256'] and p.stat().st_size==m['export_outputs'][n]['bytes']
assert h(outputs['quod.x86_64'])==m['template']['sha256']
pre=load(ev/'inputs/preflight01.json')
for n,r in pre['files'].items():assert h(r['path'])==h(root/n)==r['sha256'] and Path(r['path']).stat().st_mode&0o7777==r['mode']
outer=load(ev/'logs/physical-preparation-build01.json')
assert outer['passed'] and outer['true_child_exit']==0 and outer['explicit_completion'] and not outer['timed_out'] and not outer['reader_errors'] and all(outer['eof'].values())
private=TASK/'private/runs/physical-preparation-build01';assert private.stat().st_mode&0o7777==0o700
for name,v in outer['driver_inputs'].items():assert h(private/'driver-inputs'/name)==h(ev/name)==v
for kind,r in outer['streams'].items():
 p=Path(r['path']);assert p.stat().st_mode&0o7777==0o600 and h(p)==r['sha256'] and p.stat().st_size==r['bytes']
 q=ev/'logs'/('physical-preparation-build01-'+kind+'.log')
 assert h(q)==r['sanitized_sha256'] and q.read_bytes()==re.sub(rb'(?i)LHR-[A-Za-z0-9]+',b'<device-serial-redacted>',p.read_bytes())
assert h(root/'client/godot/Main.cs')=='e9c010f71a9c1369fd5b451fe1d7fa275948089b3a96e69fe6d8f21b543fec1e'
cache=TASK/'cache/physical-preparation01-build-verification02-hashes.json';d.write(cache)
report={'passed':True,'scope':'Compiled offline diagnostic; no functional/native/physical execution',
 'accepted_input_manifest':str(base_path),'accepted_inputs':92,'staged_inputs':93,'live_production_inputs_changed':0,
 'added_supplied_inputs':sorted(added),'staged_dispatch_overrides':sorted(changed),'presentation_check_retained':True,
 'physical04_partial_unchanged':True,'exports':196,'export_bytes':sum(r['bytes'] for r in m['export_outputs'].values()),
 'dll':{'path':next(n for n in outputs if Path(n).name=='Quod.dll'),**m['export_outputs'][next(n for n in outputs if Path(n).name=='Quod.dll')]},
 'pck':m['export_outputs']['quod.pck'],'engine':m['template'],'commands':commands,
 'build_driver_exit':outer['true_child_exit'],'build_wrapper_exit':0,'build_explicit_completion':True,
 'build_eof':outer['eof'],'timed_out':False,'reader_errors':[],
 'native_and_physical':'UNRUN','distributable':False,'core189_and_server1432':'Unchanged evidence reused; no suite execution',
 'digest_cache':{'path':str(cache),'sha256':raw(cache),'hits':d.hits,'new_files':d.new,'new_bytes':d.bytes}}
(ev/'inputs/build-verification02.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report))
