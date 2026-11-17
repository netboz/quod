"""Prepare once offline; use existing live owners only after fresh coordination.

The supported interactive tool invocation MUST use tty:true. --offline performs
no process/window/device/socket/display query and starts no fixture or runtime.
"""
import argparse,hashlib,json,os,re,shutil,subprocess,sys
from pathlib import Path
sys.dont_write_bytecode=True
root=Path.cwd();ev=Path(__file__).resolve().parent
sys.path.insert(0,str(ev.parent/'godot-m4-vive-physical-20261029'))
from environment import TASK
from cue_hashes import Digests,key,raw
p=argparse.ArgumentParser();mode=p.add_mutually_exclusive_group(required=True)
mode.add_argument('--offline',action='store_true');mode.add_argument('--start-live',action='store_true')
p.add_argument('--manifest',type=Path);p.add_argument('--prepared',type=Path);p.add_argument('--label');a=p.parse_args()
os.umask(0o077)
def verify_payload(path):
    m=json.loads(path.read_text());assert m['passed'] and m['diagnostic_physical_partial'] and not m['distributable'] and not m['compiled_application_inputs_copied']
    cache=Path(m['digest_cache']['path']);assert raw(cache)==m['digest_cache']['sha256'];d=Digests()
    for r in json.loads(cache.read_text())['records']:d.values[tuple(r['stat_key'])]=r['sha256']
    dist=Path(m['export_executable']).parent
    assert {str(f.relative_to(dist)) for f in dist.rglob('*') if f.is_file()}==set(m['export_outputs'])
    for n,r in m['export_outputs'].items():
        q=dist/n;assert key(q) in d.values and d.h(q)==r['sha256'] and q.stat().st_size==r['bytes']
    for n,h in m['live_source_inputs'].items():assert d.h(root/n)==h
    return m,d
if a.offline:
    assert a.manifest and not a.prepared and not a.label
    m,d=verify_payload(a.manifest)
    destination=TASK/'private/morning-launch-inputs02';destination.mkdir(mode=0o700,exist_ok=False)
    owners=destination/'unchanged-owners';owners.mkdir()
    copied={}
    for relative in ['godot-m4-vive-retest-20261030/physical09.py','godot-m4-vive-physical-20261029/manual_run.py','godot-m4-vive-physical-20261029/environment.py','godot-m4-vive-physical-20261029/publication.py']:
        source=ev.parent/relative;q=owners/relative;q.parent.mkdir(mode=0o700,exist_ok=True);shutil.copy2(source,q)
        copied[relative]={'path':str(q),'sha256':raw(q),'mode':q.stat().st_mode&0o7777};assert raw(source)==raw(q)
    assert copied['godot-m4-vive-retest-20261030/physical09.py']['sha256']=='360b166bacb988cb972f53f1d78df15bca70baf95e4a7354c29094fc5cb053c0'
    assert copied['godot-m4-vive-physical-20261029/manual_run.py']['sha256']=='2620ffe864b19135f1557e19280cec34fe18c19ac51f940379573da56b0e9639'
    assert (TASK/'artifacts/server-runtime-restoration05/_build/prod/lib/quod/ebin/quod_client_view.beam').is_file()
    assert (TASK/'artifacts/server-runtime-restoration05/_build/prod/lib/gproc/ebin/gproc.app').is_file()
    assert (TASK/'artifacts/server-runtime-restoration05/_build/test/lib/quod/test/quod_lifecycle_single_path_tests.beam').is_file()
    server_manifest=root/'doc/evidence/godot-m4-vive-retest-20261030/inputs/server-runtime-restoration05.json'
    assert raw(server_manifest)=='c8c7687aef397d7f4d04e91d8520bb1c7a96fc64cd0bd2c177931473fd665eeb'
    closure=root/'_build/godot-m4-r2-coordinator-20261029/closure-preflight-check-73.json'
    assert raw(closure)=='44452b7025d16e31630e27f706f9d75ba651e6fd5e105222d90857cf3eec9906'
    custody=TASK/'cache/coordinator-retest85-hashes.json'
    assert raw(custody)=='3e8d661ce99c7af6a311bddb38ba3ea092b95586409a37b9b2db7486e1e04354'
    for r in json.loads(custody.read_text())['records']:d.values[tuple(r['stat_key'])]=r['sha256']
    server=json.loads(server_manifest.read_text());server_bindings={}
    for n in ['_build/prod/lib/quod/ebin/quod_client_view.beam','_build/prod/lib/gproc/ebin/gproc.app','_build/test/lib/quod/test/quod_lifecycle_single_path_tests.beam']:
        q=Path(server['stage'])/n;r=server['files'][n]
        assert key(q) in d.values and d.h(q)==r['sha256'] and q.stat().st_size==r['bytes'] and q.stat().st_mode&0o7777==r['mode']
        server_bindings[n]={**r,'path':str(q),'stat_key':key(q)}
    runtime_manifest=root/'doc/evidence/godot-m4-r2-20261029/inputs/runtime-compatible02-install.json'
    assert raw(runtime_manifest)=='4ed361f26f8bedf3c17831b253099aac0460c3611ff4f1118777c6d7c1907c36'
    runtime=json.loads(runtime_manifest.read_text());assert runtime['child_exit']==0 and runtime['commit']=='59be345db769a89c93d1bdf6ed8316fa6209d8ae'
    runtime_root=Path('/home/yan/.cache/quod-m4-r2-artifacts/runtime/monado-compatible02-install')
    runtime_bindings={}
    for n in ['bin/monado-service','bin/monado-ctl','share/openxr/1/openxr_monado.json','lib/libopenxr_monado.so','lib/libmonado.so.25.1.0']:
        q=runtime_root/n;r=runtime['installed_outputs'][n]
        assert q.is_file() and not q.is_symlink() and q.stat().st_mode==int(r['mode'],8)
        runtime_bindings[n]={**r,'path':str(q),'stat_key':key(q),'custody':'accepted pinned installation reference; current presence/mode/stat only, no runtime bytes reread'}
    # Reuse the qualified live preflight itself. Only future case/path/payload
    # labels and its digest-cache import change; all ownership/provider/bounds
    # code remains from the existing owner. It is NOT executed offline.
    source=ev.parent/'godot-m4-vive-mapped21-20261031/prepare.py';before=source.read_text()
    text=before.replace("label='native-vive-product21';private=TASK/'private/case21-preparation01'","label=sys.argv[1];assert re.fullmatch(r'native-vive-product[0-9]+',label);private=TASK/'private'/(label+'-preparation')")
    text=text.replace('physical21.py','physical-morning.py').replace('private-physical21.py','private-physical-morning.py')
    text=text.replace("root/'doc/evidence/godot-m4-vive-workspace-cue-20261031/inputs/client-workspace-cue01-manifest.json'",repr(str(a.manifest.resolve())))
    text=text.replace("assert d.h(manifest)=='4e6bcf7daf995305e004eb8a9164cb862f7aa84dd257404f37c089aa672ff884'","manifest=Path(manifest);assert d.h(manifest)=="+repr(raw(a.manifest)))
    # The generated preflight imports/copies THIS stat-bound digest binding.
    (destination/'case_hashes.py').write_text('import sys\nfrom pathlib import Path\nsys.path.insert(0,'+repr(str(ev))+')\nfrom cue_hashes import *\nSOURCES.append((Path('+repr(m['digest_cache']['path'])+'),'+repr(m['digest_cache']['sha256'])+'))\n')
    text=text.replace("shutil.copy2(ev/'case_hashes.py',physical.parent/'case_hashes.py')","shutil.copy2(Path(__file__).resolve().parent/'case_hashes.py',physical.parent/'case_hashes.py')")
    text=text.replace("TASK/'cache/mapped21-preparation-used-digests.json'","TASK/'cache'/(label+'-preparation-used-digests.json')")
    retained=destination/'prepare_live.py';retained.write_text(text);retained.chmod(source.stat().st_mode&0o7777)
    (destination/'prepare-original.py').write_bytes(source.read_bytes())
    patch=subprocess.run(['git','diff','--no-index','--binary',str(destination/'prepare-original.py'),str(retained)],capture_output=True);assert patch.returncode==1
    (destination/'prepare-adaptation.patch').write_bytes(patch.stdout)
    # Compile syntax only, without running imports or touching live owners.
    compile(text,str(retained),'exec');compile((destination/'case_hashes.py').read_text(),str(destination/'case_hashes.py'),'exec')
    value={'passed':True,'offline_only':True,'manifest':str(a.manifest.resolve()),'manifest_sha256':raw(a.manifest),'executable':m['export_executable'],
        'prepare_live':str(retained),'prepare_live_sha256':raw(retained),'original_preflight_sha256':raw(source),'digest_owner_sha256':raw(destination/'case_hashes.py'),
        'unchanged_owners':copied,'tty_required':True,'server_stage':str(TASK/'artifacts/server-runtime-restoration05'),
        'server_closure_reference':'accepted73:34apps/944modules/250priv/2helpers; reused, not rerun',
        'server_manifest':{'path':str(server_manifest),'sha256':raw(server_manifest)},'server_bindings':server_bindings,
        'accepted_closure':{'path':str(closure),'sha256':raw(closure)},
        'runtime_manifest':{'path':str(runtime_manifest),'sha256':raw(runtime_manifest)},'runtime_bindings':runtime_bindings,
        'startup_seconds':30,'single_inventory_seconds':5,'manual_seconds':1800,'close_seconds':60,'wrapper_seconds':2100,
        'sign_in':'fresh at future launch; expiry remains an earlier cutoff; never silently renew/replay',
        'native_or_physical_execution':'UNRUN; separate fresh coordinator authority required','old_case_targets':'all1..21 closed; never reused'}
    result=destination/'prepared.json';result.write_text(json.dumps(value,indent=2)+'\n')
    print(json.dumps({'passed':True,'prepared':str(result),'sha256':raw(result),'native_started':False,'hardware_queried':False}),flush=True)
else:
    assert a.prepared and a.label and not a.manifest and sys.stdin.isatty(),'Future live invocation requires explicit tty:true ownership'
    assert re.fullmatch(r'native-vive-product[0-9]+',a.label) and int(a.label.removeprefix('native-vive-product'))>21
    v=json.loads(a.prepared.read_text());assert v['passed'] and v['offline_only'];m,d=verify_payload(Path(v['manifest']))
    assert raw(v['manifest'])==v['manifest_sha256'] and raw(v['prepare_live'])==v['prepare_live_sha256']
    directory=Path(v['prepare_live']).parent;assert raw(directory/'case_hashes.py')==v['digest_owner_sha256']
    for r in v['unchanged_owners'].values():assert raw(r['path'])==r['sha256'] and Path(r['path']).stat().st_mode&0o7777==r['mode']
    for r in v['server_bindings'].values():assert list(key(Path(r['path'])))==r['stat_key'] and Path(r['path']).stat().st_mode&0o7777==r['mode']
    for r in v['runtime_bindings'].values():assert list(key(Path(r['path'])))==r['stat_key'] and Path(r['path']).stat().st_mode==int(r['mode'],8)
    # No loop, retry, new deadline, reauthentication or bypass on failure.
    status=subprocess.run([sys.executable,'-B',v['prepare_live'],a.label],cwd=root).returncode
    if status:raise SystemExit(status)
    private=TASK/'private'/(a.label+'-preparation')/'unchanged-owners'
    physical=private/'godot-m4-vive-retest-20261030/physical-morning.py'
    wrapper=private/'godot-m4-vive-physical-20261029/manual_run.py'
    os.execv(sys.executable,[sys.executable,'-B',str(wrapper),a.label+'-run','--',sys.executable,'-B',str(physical),a.label,'--client-manifest',v['manifest'],'--require-wands'])
