"""Case13 current-owner/provider preflight and private unchanged invocation bytes."""
import importlib.util,json,os,re,shutil,subprocess,sys
from pathlib import Path
sys.dont_write_bytecode=True
from freeze_hashes import Digests,TASK,raw,key
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent;d=Digests()
label='native-vive-product13';private=TASK/'private/case13-preparation01'
assert all(not p.exists() for p in [TASK/'private'/label,TASK/'private/runs'/(label+'-run'),TASK/'private/runs'/(label+'-focus-run'),
    TASK/'private'/(label+'-focus'),TASK/'private'/('quod-m4-live-'+label+'-server'),
    root/'doc/evidence/godot-m4-vive-retest-20261030'/label,private])
assert subprocess.check_output(['git','branch','--show-current']).decode().strip()=='worktree/pearl-stone'
assert subprocess.check_output(['git','rev-parse','HEAD']).decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert not subprocess.check_output(['git','diff','--cached','--name-only'])
private.mkdir(mode=0o700);driver_root=private/'unchanged-owners';driver_root.mkdir(mode=0o700)
sources={}
for relative in ['doc/evidence/godot-m4-vive-retest-20261030/physical09.py',
    'doc/evidence/godot-m4-vive-physical-20261029/manual_run.py',
    'doc/evidence/godot-m4-vive-physical-20261029/environment.py',
    'doc/evidence/godot-m4-vive-physical-20261029/publication.py']:
    p=root/relative;q=driver_root/p.parent.name/p.name;q.parent.mkdir(mode=0o700,exist_ok=True);shutil.copy2(p,q)
    assert raw(q)==d.h(p) and q.stat().st_mode&0o7777==p.stat().st_mode&0o7777
    sources[relative]={'sha256':d.h(p),'bytes':p.stat().st_size,'mode':p.stat().st_mode&0o7777,'private_executed_copy':str(q)}
assert sources['doc/evidence/godot-m4-vive-retest-20261030/physical09.py']['sha256']=='360b166bacb988cb972f53f1d78df15bca70baf95e4a7354c29094fc5cb053c0'
assert sources['doc/evidence/godot-m4-vive-physical-20261029/manual_run.py']['sha256']=='2620ffe864b19135f1557e19280cec34fe18c19ac51f940379573da56b0e9639'
manifest=root/'doc/evidence/godot-m4-vive-preparation-20261030/inputs/client-physical-preparation01-manifest.json'
assert d.h(manifest)=='e34159ae24d5ec0ddf6f2324a93c3352203337d886f25b8aa0ff3e7074e01e53'
assert d.h(root/'doc/evidence/godot-m4-vive-retest10-20261030/focus_events.py')=='a7b584c8b137b5617b89a98e57f6f42e895d3247278b4c3de52b595ecbea5889'
assert d.h(root/'nimbalyst-local/handoffs/godot-m4-vive-focus-recipient-live-prompt-98.md')=='a6d42471f7188c9720b4c653bba178dc6a6cbb7988c15ae27341a62a1501386a'
payload=json.loads(manifest.read_text());exe=Path(payload['export_executable'])
assert len(payload['export_outputs'])==196
for n,row in payload['export_outputs'].items():
    p=exe.parent/n;assert key(p) in d.values and d.h(p)==row['sha256'] and p.stat().st_size==row['bytes']
original=TASK/'private/coordinator-role-binding98/bindings.json';roles=private/'bindings.json'
assert original.stat().st_mode&0o7777==0o600 and original.parent.stat().st_mode&0o7777==0o700
assert raw(original)=='57e559cffa0e38d6240174e9b82c6839fd0e90bd08cb48894104f61d88a7cba7'
shutil.copy2(original,roles);assert raw(roles)==raw(original)
bindings=json.loads(roles.read_text());assert len(bindings)==1 and bindings[0]['role']=='coordinator'
owners=subprocess.run(['ps','-eo','pid=,comm='],capture_output=True,timeout=5);assert owners.returncode==0
conflicts=[line for line in owners.stdout.decode().splitlines() if any(s in line.lower() for s in ['monado','godot','quod.x86','steamvr','vrserver','vrcompositor'])]
assert not conflicts,'Another runtime/app is present; no interference'
windows=json.loads(subprocess.check_output(['hyprctl','-j','clients'],stderr=subprocess.PIPE,timeout=5))
for binding in bindings:
    proc=Path('/proc')/str(binding['pid']);s=(proc/'exe').stat();info=(proc/'stat').read_text();started=info[info.rfind(')')+2:].split()[19]
    assert (started,s.st_dev,s.st_ino)==(binding['starttime'],binding['device'],binding['inode'])
    assert (proc/'exe').resolve()==Path(binding['executable']).resolve()
    matched=[w for w in windows if w.get('pid')==binding['pid'] and w.get('address','').lower()==binding['address'].lower() and w.get('mapped')]
    assert len(matched)==1,'Supplied coordinator window is no longer current'
spec=importlib.util.spec_from_file_location('current_case13_display',root/'doc/evidence/godot-m4-vr-20261029/vive_display.py')
display_module=importlib.util.module_from_spec(spec);spec.loader.exec_module(display_module)
display=display_module.ViveDisplay(private);probe=TASK/'builds/display-inventory02/display-inventory'
probe_source=root/'doc/evidence/godot-m4-vr-20261029/display_inventory.c'
for p in [probe,probe_source,root/'doc/evidence/godot-m4-vr-20261029/vive_display.py']:
    q=private/p.name;shutil.copy2(p,q);assert raw(q)==d.h(p)
record={'passed':False,'case_label':label,'runtime_started':False,'lease_requested':False,
 'unchanged_private_invocation_sources':sources,'actual_coordinator_binding_current':True,
 'binding_sha256':raw(roles),'binding_bytes':roles.stat().st_size,'raw_binding_public':False,
 'payload_manifest_sha256':d.h(manifest),'payload_outputs':196,'payload_strict_cache_reused':True,
 'qualified_server_stage':str(TASK/'artifacts/server-runtime-restoration05'),
 'qualified_closure_reused':'accepted73:34apps/944modules/250priv; not rerun','other_runtime_app_conflicts':False}
try:
    display.enable();command=[str(probe),'/dev/dri/card1'];result=subprocess.run(command,capture_output=True,timeout=5)
    for kind,data in [('stdout',result.stdout),('stderr',result.stderr)]:
        q=private/('provider-'+kind+'.raw');q.write_bytes(data);q.chmod(0o600)
    record.update(provider_command=command,provider_true_child_exit=result.returncode,
        provider_complete=b'DISPLAY_INVENTORY_COMPLETE status=0' in result.stdout,
        hdmi_offer=bool(re.search(rb'LEASE_NAME id=\d+ name=HDMI-A-1\n',result.stdout)),
        connector828_offered=bool(re.search(rb'LEASE_CONNECTOR id=\d+ drm_connector=828\n',result.stdout)),
        provider_stdout_sha256=raw(private/'provider-stdout.raw'),provider_stderr_sha256=raw(private/'provider-stderr.raw'))
    assert result.returncode==0 and record['provider_complete'] and record['hdmi_offer'] and record['connector828_offered'],'Current provider has no exact Vive offer; no runtime launched'
    record['passed']=True
finally:
    display.restore();record['hdmi_restored_disabled']=any(m['name']=='HDMI-A-1' and m['disabled'] for m in display.record['after']['monitors'])
    record['other_displays_unchanged']=display.record['desktop_unchanged'];record['config_unchanged']=display.record['config_unchanged']
    (private/'preparation-private.json').write_text(json.dumps(record,indent=2)+'\n')
    (ev/'preexecution.json').write_text(json.dumps(record,indent=2)+'\n');d.write(TASK/'cache/focus13-preparation-used-digests.json')
    print(json.dumps({'passed':record['passed'],'current_provider_vive_offer':record.get('hdmi_offer'),
        'provider_true_exit':record.get('provider_true_child_exit'),'binding_current':True,
        'private_invocation_owners_unchanged':True,'runtime_started':False,'hdmi_restored_disabled':record['hdmi_restored_disabled']}))
if not record['passed']:raise SystemExit(1)
