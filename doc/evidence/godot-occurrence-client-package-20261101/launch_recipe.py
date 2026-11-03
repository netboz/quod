"""Prepare the next human launch offline; never start a fixture or application."""
import argparse,json,os,shlex
from pathlib import Path
from hashes import Digests,TASK,key,raw
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('--label',required=True);a=p.parse_args()
assert a.label.replace('-','').isalnum()
assert not (TASK/'private'/a.label).exists()
assert not (TASK/'private'/('quod-m4-live-'+a.label+'-server')).exists()
inspection=json.loads((ev/'inputs/package-inspection01.json').read_text());package=Path(inspection['extracted'])
d=Digests();cache=Path(inspection['digest_cache']['path']);assert raw(cache)==inspection['digest_cache']['sha256']
for row in json.loads(cache.read_text())['records']:d.values[tuple(row['stat_key'])]=row['sha256']
index=json.loads((package/'package-manifest.json').read_text())
for name,row in index['files'].items():
    assert d.h(package/name)==row['sha256'] and (package/name).stat().st_size==row['bytes']
manual=root/ev.relative_to(root)/'manual_run.py';server_label=a.label+'-server'
server=json.loads((ev/'inputs/server-occurrence-journey01-server.json').read_text())
assert server['child_exit']==0 and not server['runtime_recompiled'] and len(server['executed_current_sources'])==14
for name,row in server['executed_current_sources'].items():
    assert d.h(root/name)==row['sha256']
    if 'compiled_object' in row:
        obj=row['compiled_object'];assert d.h(Path(obj['path']))==obj['sha256']

stage=TASK/'builds/answer-policy-clean-focused06/source'
fixture=['python3','-B',str(manual),a.label+'-fixture-wrapper','--','python3','-B',str(ev/'serve.py'),server_label,'--stage',str(stage),'--profile','test','--qualified','--presentation-source','--clean-manifest',str(stage.parent/'source-manifest.json'),'--affected-wire',str(root/'doc/evidence/godot-space-experience-20261101/inputs/space-name-owner03.json')]
client=['python3','-B',str(manual),a.label+'-client-wrapper','--','python3','-B',str(ev/'human.py'),'--label',a.label,'--package',str(package),'--server-label',server_label]
out=TASK/'private'/('occurrence-launch-recipe-'+a.label);out.mkdir(mode=0o700,exist_ok=False)
record={'prepared_only':True,'nothing_launched':True,'label':a.label,'package':str(package),'archive_sha256':inspection['archive_sha256'],
 'package_index_sha256':d.h(package/'package-manifest.json'),'profile':str(TASK/'private'/a.label/'sandbox/home/profile'),'qualified_server':{'stage':server['stage'],'clean_source_binding':server['clean_source_binding'],'executed_sources':server['executed_current_sources']},'executable_stat_key':key(package/'quod.x86_64'),
 'executable_sha256':d.h(package/'quod.x86_64'),'fixture':{'cmd':shlex.join(fixture),'tty':True},
 'client':{'cmd':shlex.join(client),'tty':True},'participant_seconds':1800,'normal_close_seconds':60,'wrapper_seconds':2100,
 'required_order':['fresh explicit coordinator/user request','start fixture PTY and observe its actual M1B_READY','start client PTY; report actual mapped window','human alone performs domain actions','finish newline once to owned client PTY, await normal close/EOF','stop newline once to owned fixture PTY, await normal exit/EOF'],
 'no_automatic_signup_submit_save_or_replay':True,'authentication_expiry':'existing signed absolute cutoff; no hidden renewal',
 'first_action':'follow the current highlighted native key/connect/account action',
 'ordinary_user_launch':'./quod --xr-mode off -- --profile /absolute/private/profile --node https://YOUR-NODE:14570 --ca /absolute/trusted-ca.pem',
 'ordinary_user_prerequisite':'supply a real server and its trust; package contains no server, account, credentials or fixture',
 'source_bindings':{str(f.relative_to(root)):d.h(f) for f in [manual,ev/'human.py',ev/'serve.py',ev/'isolation.py',ev/'launch_recipe.py',ev/'hashes.py',ev/'godot_m3b_fixture.erl',ev/'godot_m3b_physics_fixture.erl']}}
d.write(TASK/'cache'/('occurrence-launch-'+a.label+'-digests.json'));record['digest_cache']={'path':str(TASK/'cache'/('occurrence-launch-'+a.label+'-digests.json')),'sha256':raw(TASK/'cache'/('occurrence-launch-'+a.label+'-digests.json'))}
(out/'prepared.json').write_text(json.dumps(record,indent=2)+'\n')
(ev/'inputs/launch-recipe.json').write_text(json.dumps({'passed':True,'prepared':str(out/'prepared.json'),'sha256':raw(out/'prepared.json'),'nothing_launched':True},indent=2)+'\n')
print(json.dumps({'prepared':str(out/'prepared.json'),'nothing_launched':True,'both_interactive_wrappers_tty':True}))
