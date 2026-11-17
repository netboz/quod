"""Read-only current ownership and exact preexecution custody for authorized12."""
import hashlib,importlib.util,json,os,shutil,subprocess,sys,time
from pathlib import Path
sys.dont_write_bytecode=True
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent
previous=ev.parent/'godot-m4-vive-retest10-20261030'
sys.path.insert(0,str(ev))
from freeze_hashes import Digests,TASK,key,raw,SOURCES
SOURCES.append((TASK/'cache/coordinator-retest10-final86-hashes.json','a1c6e1b72b697cc47bfec27971bfb358731385748adffdf961fb76f423f635ba'))
if sys.argv[1:]!=['--child']:
    assert not sys.argv[1:]
    private=TASK/'private/metadata-inputs/focus12-prepare01';private.mkdir(mode=0o700,exist_ok=False)
    shutil.copy2(ev/'prepare.py',private/'prepare.py')
    command=[sys.executable,'-B',str(ev/'prepare.py'),'--child'];started=time.monotonic()
    with (private/'stdout.raw').open('xb') as out,(private/'stderr.raw').open('xb') as err:
        result=subprocess.run(command,stdout=out,stderr=err,timeout=120)
    streams={}
    for name in ['stdout','stderr']:
        p=private/(name+'.raw');p.chmod(0o600);target=ev/('prepare01-'+name+'.log');target.write_bytes(p.read_bytes())
        streams[name]={'raw':str(p),'sha256':raw(p),'bytes':p.stat().st_size,'eof':True}
    receipt={'command':command,'true_child_exit':result.returncode,'timed_out':False,'elapsed_seconds':time.monotonic()-started,'streams':streams}
    (ev/'prepare01-result.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt))
    raise SystemExit(result.returncode)
d=Digests();label='native-vive-product12'
paths=[TASK/'private'/label,TASK/'private/runs'/(label+'-run'),
    TASK/'private/runs'/(label+'-focus-run'),TASK/'private'/(label+'-focus'),
    TASK/'private'/('quod-m4-live-'+label+'-server'),
    ev.parent/'godot-m4-vive-retest-20261030'/label,
    ev.parent/'godot-m4-vive-charged-20261029'/label,
    ev.parent/'godot-m4-vive-physical-20261029/logs'/(label+'-run.json')]
assert all(not p.exists() and not p.is_symlink() for p in paths),'Case12 label already used'
assert subprocess.check_output(['git','branch','--show-current']).decode().strip()=='worktree/pearl-stone'
assert subprocess.check_output(['git','rev-parse','HEAD']).decode().strip()=='293cf6115c0a6b18315eccdbb42cbca396f443d3'
assert subprocess.check_output(['git','rev-parse','HEAD^']).decode().strip()=='f716ddf5e578df957a5b18421a0727a32c634f87'
assert not subprocess.check_output(['git','diff','--cached','--name-only'])
assert hashlib.sha256(subprocess.check_output(['git','diff','--binary','HEAD'])).hexdigest()=='fc2482aecbfb1803f7328e4b216a449252e6d5f6bfa2a9aa5f21da5b7f2738ef'
manifest=ev.parent/'godot-m4-vive-preparation-20261030/inputs/client-physical-preparation01-manifest.json'
driver=ev.parent/'godot-m4-vive-retest-20261030/physical09.py';observer=previous/'focus_events.py'
assert d.h(manifest)=='e34159ae24d5ec0ddf6f2324a93c3352203337d886f25b8aa0ff3e7074e01e53'
assert d.h(driver)==json.loads((ev/'publisher-source-delta.json').read_text())['existing_changed_sources']['doc/evidence/godot-m4-vive-retest-20261030/physical09.py']['after_sha256']
assert d.h(observer)=='bb63ff9db8f3aef231f22043e8336c263afcf52b553c908419ff3e0abdd584e2'
owners=subprocess.run(['ps','-eo','pid=,comm='],capture_output=True,timeout=5);assert owners.returncode==0
active=[s for s in owners.stdout.decode().splitlines() if any(n in s.lower() for n in ['monado','godot','quod.x86','steamvr','vrserver','vrcompositor'])]
assert not active,active
monitors=json.loads(subprocess.check_output(['hyprctl','-j','monitors','all'],timeout=5))
windows=json.loads(subprocess.check_output(['hyprctl','-j','clients'],timeout=5))
fields=['name','disabled','width','height','refreshRate','x','y','scale','transform','dpmsStatus']
names=[str(p.relative_to(root)) for p in [driver,manifest,observer]]+[
    'doc/evidence/godot-m4-vive-physical-20261029/manual_run.py',
    'doc/evidence/godot-m4-vive-physical-20261029/serve.py',
    'doc/evidence/godot-m4-vive-physical-20261029/environment.py',
    'doc/evidence/godot-m4-vive-physical-20261029/godot_m3b_fixture.erl',
    'doc/evidence/godot-m4-vive-physical-20261029/godot_m3b_physics_fixture.erl',
    'doc/evidence/godot-m4-r2-20261029/private_vive.py',
    'doc/evidence/godot-m4-vr-20261029/vive_display.py',
    'doc/evidence/godot-m4-vive-physical-20261029/publication.py',
    'doc/evidence/godot-m4-vive-focus12-20261030/capture.py',
    'doc/evidence/godot-m4-vive-focus12-20261030/arm.py']
target=TASK/'private/build-inputs'/label;target.mkdir(mode=0o700,exist_ok=False);sources={}
for n in names:
    p=root/n;q=target/n;q.parent.mkdir(mode=0o700,parents=True,exist_ok=True);shutil.copy2(p,q)
    digest=d.h(p);assert raw(q)==digest
    sources[n]={'sha256':digest,'mode':p.stat().st_mode&0o7777,'bytes':p.stat().st_size,'saved':str(q)}
record={'passed':True,'label':label,'runtime_started':False,'unused_paths_checked':[str(p) for p in paths],
    'active_runtime_app_processes':active,'other_mapped_windows':sum(bool(w.get('mapped')) for w in windows),
    'monitors':[{k:m.get(k) for k in fields} for m in monitors],'sources':sources,
    'server_stage':str(TASK/'artifacts/server-runtime-restoration05'),
    'qualified_closure_reused':'root73:34apps/944modules/250priv/2helpers; no replay',
    'prior_offer79_is_not_current_readiness':True,'power_answer_is_not_current_pose_readiness':True,
    'capacity_free_bytes':shutil.disk_usage(TASK).free,'product_or_qualified_helper_source_changes':0}
(ev/'preexecution.json').write_text(json.dumps(record,indent=2)+'\n');d.write(ev/'prepare-used-digests.json')
print(json.dumps({'passed':True,'label':label,'source_copies':len(sources),'active_runtime_app_processes':active,'runtime_started':False}))
