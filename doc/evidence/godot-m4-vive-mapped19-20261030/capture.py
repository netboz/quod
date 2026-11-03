"""Capture an existing read-only Godot snapshot and bind only this owned client."""
import hashlib,json,math,os,re,subprocess,sys,time
from pathlib import Path
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent
assert len(sys.argv)==2 and re.fullmatch(r'[a-z0-9-]+',sys.argv[1]);name=sys.argv[1]
task=Path('/data/quod-m4-vr-ca84d4f8-20261029');private=task/'private/native-vive-product19'
def key(p):
    s=p.stat();return [s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_ctime_ns]
manifest=json.loads((root/'doc/evidence/godot-m4-vive-runtime-cue-20261030/inputs/client-runtime-cue01-manifest.json').read_text())
executable=Path(manifest['export_executable']);expected=executable.stat()
windows=json.loads(subprocess.check_output(['hyprctl','-j','clients'],stderr=subprocess.PIPE,timeout=5));owned=[]
for w in windows:
    if not w.get('mapped'):continue
    p=Path('/proc')/str(w['pid'])/'exe'
    try:s=p.stat()
    except FileNotFoundError:continue
    if (s.st_dev,s.st_ino)==(expected.st_dev,expected.st_ino) and p.resolve()==executable.resolve():owned.append(w)
assert len(owned)==1 and re.fullmatch(r'0x[0-9a-fA-F]+',owned[0]['address'])
pid=owned[0]['pid'];address=owned[0]['address'];proc=Path('/proc')/str(pid)
stat=(proc/'stat').read_text();started=stat[stat.rfind(')')+2:].split()[19];hz=os.sysconf('SC_CLK_TCK')
raw=private/'client-result.raw.json';before=key(raw);data=raw.read_bytes();assert key(raw)==before
payload=json.loads(data);last=payload['snapshots'][-1];node=last['geometry']['node']
store=private/'read-only-captures';store.mkdir(mode=0o700,exist_ok=True)
copy=store/(name+'.raw.json');assert not copy.exists();copy.write_bytes(data);copy.chmod(0o600)
ownerfile=task/'private/native-vive-product19-invocation.json'
if ownerfile.exists():
    owner=json.loads(ownerfile.read_text())
    assert owner['pid']==pid and owner['address']==address and owner['start_ticks']==started
    assert owner['executable_dev_inode']==[expected.st_dev,expected.st_ino]
else:
    mono=time.monotonic();uptime=float(Path('/proc/uptime').read_text().split()[0]);elapsed=uptime-int(started)/hz
    deadline=mono+1800-math.ceil(elapsed)-5
    assert elapsed>=0 and deadline>time.monotonic()
    owner={'pid':pid,'address':address,'start_ticks':started,'executable':str(executable),
        'executable_dev_inode':[expected.st_dev,expected.st_ino],'instance_signature':os.environ['HYPRLAND_INSTANCE_SIGNATURE'],
        'deadline_monotonic':deadline,'derivation':{'observed_monotonic':mono,'observed_uptime':uptime,'elapsed_since_client_start':elapsed,'ticks_per_second':hz,
            'formula':'observed_monotonic +1800-ceil(elapsed_since_client_start)-5; client launch precedes driver participant timer. Never recomputed/reset.'},
        'private_dir':str(task/'private/native-vive-product19-focus')}
    ownerfile.write_text(json.dumps(owner,indent=2)+'\n');ownerfile.chmod(0o600)
active=json.loads(subprocess.check_output(['hyprctl','-j','activewindow'],stderr=subprocess.PIPE,timeout=5))
rows=[]
for s in node['sources']:
    rows.append({'hand':s['hand'],'current':s['current'],
        'aim':None if s['native_aim'] is None else {k:s['native_aim'][k] for k in ['tracked','confidence']},
        'grip':None if s['native_grip'] is None else {k:s['native_grip'][k] for k in ['tracked','confidence']},
        'models':len(s['models']),'visible_roots':sum(m['visible_in_tree'] for m in s['models']),
        'visible_meshes':sum(m['visible_in_tree'] for model in s['models'] for m in model['meshes'])})
summary={'capture':name,'observed_at_monotonic':time.monotonic(),'snapshot_phase':last['phase'],'node_utc':node['utc'],
    'frames':last['frames'],'pid':pid,'address':address,'executable_dev_inode':[expected.st_dev,expected.st_ino],
    'deadline_monotonic':owner['deadline_monotonic'],'remaining_seconds':owner['deadline_monotonic']-time.monotonic(),
    'deadline_derivation':owner['derivation'],'compositor_instance_sha256':hashlib.sha256(owner['instance_signature'].encode()).hexdigest(),
    'active_owned':active.get('pid')==pid and active.get('address')==address,'window_focused':node['window_focused'],
    'lifecycle':{k:v for k,v in node['adapter_lifecycle'].items() if k!='calibration'},'native_session':node['session_state'],
    'head':None if node['head'] is None else {k:node['head'][k] for k in ['tracked','confidence']},
    'sources':rows,'metrics':last['metrics'],'raw_snapshot_sha256':hashlib.sha256(data).hexdigest(),
    'raw_snapshot_stat_key':before,'raw_geometry_public':False,'scope':'Recorded instants only. Current(0) is not a separate freshness proof. No human interval inferred.'}
private_summary=store/(name+'-owner-summary.raw.json');assert not private_summary.exists()
private_summary.write_text(json.dumps(summary,indent=2)+'\n');private_summary.chmod(0o600)
for field in ['pid','address','executable_dev_inode','deadline_derivation']:summary.pop(field)
summary['actual_task_owner_binding_retained_privately']=True
summary['owner_binding_sha256']=hashlib.sha256(ownerfile.read_bytes()).hexdigest()
stderr=private/'client-stderr.raw'
lines=stderr.read_bytes().splitlines()
markers=[v.decode(errors='replace') for v in lines if v.startswith(b'M4_VIVE_LOOK_CUE ')]
summary['latest_cue_marker']=markers[-1] if markers else None
summary['cue_scope']='last received marker plus separately timed snapshot; no pixel or continuous interval claim'
target=ev/(name+'.json');assert not target.exists();target.write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary))
