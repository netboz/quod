"""Record an offline future VR protocol and exact ordinary engine arguments.

This creates no profile, fixture, runtime or application. The prior human
bootstrap is deliberately not presented as a current98-input companion.
"""
import json,os,shlex
from pathlib import Path
from hashes import TASK,Digests,key,raw
os.umask(0o077)
root=Path.cwd();ev=Path(__file__).resolve().parent

def client_arguments(package,profile,port,ca):
    if not isinstance(port,int) or not 0<port<65536:raise ValueError('fixture port')
    return [str(Path(package)/'quod'),'--display-driver','wayland','--audio-driver','Dummy',
            '--xr-mode','on','--rendering-method','mobile','--rendering-driver','vulkan','--',
            '--profile',str(profile),'--node','https://127.0.0.1:'+str(port),'--ca',str(ca)]

def prepare():
    d=Digests();inspection=json.loads((ev/'inputs/package-inspection01.json').read_text())
    cache=inspection['digest_cache'];assert raw(cache['path'])==cache['sha256']
    for r in json.loads(Path(cache['path']).read_text())['records']:d.values[tuple(r['stat_key'])]=r['sha256']
    package=Path(inspection['extracted']);index=json.loads((package/'package-manifest.json').read_text())
    for n,r in index['files'].items():assert d.h(package/n)==r['sha256']
    label='attention-vr-future279';private=TASK/'private'/label;server_label=label+'-server'
    assert not private.exists() and not (TASK/'private'/('quod-m4-live-'+server_label)).exists()
    stage=TASK/'builds/answer-policy-clean-focused06/source'
    server=json.loads((ev/'inputs/server-attention-package-journey01-server.json').read_text())
    assert server['child_exit']==0 and len(server['executed_current_sources'])==14
    for n,r in server['executed_current_sources'].items():assert d.h(root/n)==r['sha256']
    fixture=['python3','-B',str(ev/'manual_run.py'),label+'-fixture-wrapper','--','python3','-B',str(ev/'serve.py'),server_label,
             '--stage',str(stage),'--profile','test','--qualified','--presentation-source','--clean-manifest',str(stage.parent/'source-manifest.json'),
             '--affected-wire',str(root/'doc/evidence/godot-space-experience-20261101/inputs/space-name-owner03.json')]
    old=root/'doc/evidence/godot-steamvr-working-20261101'
    sources=[ev/'launch_recipe.py',ev/'manual_run.py',ev/'serve.py',ev/'isolation.py',ev/'hashes.py',
             old/'live.py',old/'supervision.py',old/'pipe_ownership.py',root/'doc/evidence/godot-steamvr-coordinated-20261101/VrReady269.cs']
    out=TASK/'private/attention-package-offline-recipe01';out.mkdir(mode=0o700,exist_ok=False)
    record={'prepared_only':True,'nothing_launched':True,'launch_authorized_now':False,
      'ready_to_launch_human_case':False,'current_combined_journey_reopen_qualified':False,
      'reason':'The one current companion failed in diagnostic callback cleanup; reopen is unrun. The historical269 VR bootstrap is not a current-product readiness binding.',
      'label':label,'package':str(package),'archive_sha256':inspection['archive_sha256'],
      'executable_sha256':d.h(package/'quod.x86_64'),'executable_stat_key':key(package/'quod.x86_64'),
      'profile':str(private/'profile'),'fixture':{'argv':fixture,'cmd':shlex.join(fixture),'tty':True},
      'client':{'argv_builder':str(ev/'launch_recipe.py')+'::client_arguments','package':str(package),'profile':str(private/'profile'),
        'port':'actual fresh M1B_READY.port only','ca':str(TASK/'private'/('quod-m4-live-'+server_label)/'backend-ca.pem'),'tty':True,
        'ordinary_engine_arguments':client_arguments(package,private/'profile',14570,TASK/'private'/('quod-m4-live-'+server_label)/'backend-ca.pem'),
        'example_port_is_not_a_live_endpoint':True,'qualification_flag':False},
      'process_environment':{'XR_RUNTIME_JSON':'/home/yan/.local/share/Steam/steamapps/common/SteamVR/steamxr_linux64.json','QT_QPA_PLATFORM':'xcb','DISPLAY':'preserve actual inherited value','WAYLAND_DISPLAY':'preserve actual inherited value'},
      'runtime_manifest_not_read_or_verified_now':True,'global_defaults_unchanged':True,
      'qualified_server':{'stage':server['stage'],'executed_sources':server['executed_current_sources']},
      'participant_seconds':1800,'normal_close_seconds':60,'wrapper_seconds':2100,'preparation_seconds':180,'native_admission_seconds':30,
      'authentication':'absolute signed expiry remains an earlier cutoff; no renewal or replay',
      'required_before_live_launch':['separate explicit user start and fresh physical availability','current-source readiness/bootstrap composition for this package and focused fixture, with real owner guards','fresh runtime ownership and per-process manifest verification without changing user defaults','one fresh private profile/fixture; no historical pending work','actual M1B_READY and exact new client incarnation/mapped address','same test owner sends begin only after mapped PREPARED under original bounds'],
      'READY_requires':['advancing rendered stereo frames and shouldRender','XR Focused/CanRender','head and both current supported neutral tracked controllers','current signed world/operation/controller admission','settled resources and authentic unexpired sign-in'],
      'normal_stop':'one finish through the current qualified exact-owned supervisor, client exit/EOF first, then fixture stop once; never old PTYs/PIDs',
      'human_task':'Select one visible Analyzer to open its settings. Move that same form to Personal workspace and back Near this object. Open Your attention, select one measurement request, type a short draft, then choose Later and reopen it. Do not press Apply, Send or Cancel unless explicitly choosing that domain action.',
      'task_fixture':'same-ontology analyzer/two occurrences and two independent questions from the source-bound software companion; a future bootstrap must use those existing signed owners, not replay its saved profile',
      'limits':['No current human/HMD quality claim.','No certified-negative application completion claim.','A mapped window or a valid command is not native READY.','No runtime, fixture, client, user session or auth clock starts here.'],
      'source_bindings':{str(p.relative_to(root)):d.h(p) for p in sources}}
    cache_path=TASK/'cache/attention-package-offline-recipe01-hashes.json';d.write(cache_path)
    record['digest_cache']={'path':str(cache_path),'sha256':raw(cache_path)}
    target=out/'prepared.json';target.write_text(json.dumps(record,indent=2)+'\n')
    (ev/'inputs/launch-recipe.json').write_text(json.dumps({'passed':True,'prepared':str(target),'sha256':raw(target),'nothing_launched':True,'human_launch_ready':False},indent=2)+'\n')
    print(json.dumps({'offline_recipe':str(target),'nothing_launched':True,'human_launch_ready':False}))

if __name__=='__main__':prepare()
