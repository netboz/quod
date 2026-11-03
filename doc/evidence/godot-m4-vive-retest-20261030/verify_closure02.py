"""Complete the retained closure binding using OTP's actual root, without replay."""
import json,os,subprocess,sys
sys.dont_write_bytecode=True
from pathlib import Path
from hashes import Digests,TASK,raw
os.umask(0o077);ev=Path(__file__).resolve().parent;d=Digests();h=d.h
old=json.loads((ev/'inputs/server-closure-preflight01.json').read_text());assert old['true_child_exit']==0 and '\nISSUES\t[]\n' in '\n'+old['stdout']
restored=json.loads((ev/'inputs/server-runtime-restoration05.json').read_text());assert restored['passed'];stage=Path(restored['stage'])
info=restored['digest_cache'];assert raw(info['path'])==info['sha256']
for row in json.loads(Path(info['path']).read_text())['records']:
 k=tuple(row['stat_key']);assert k not in d.values or d.values[k]==row['sha256'];d.values[k]=row['sha256']
command=[*old['command'][:-1],'io:format("SYSTEM_ROOT\\t~s~n",[code:root_dir()]),halt().']
result=subprocess.run(command,capture_output=True,timeout=20);assert result.returncode==0
line=result.stdout.decode().strip();assert line.startswith('SYSTEM_ROOT\t');system_root=line.split('\t',1)[1]
apps={};modules=[];private=[];helpers={};closure=[];dependencies={}
for line in old['stdout'].splitlines():
 fields=line.split('\t')
 if fields[0]=='APP':apps[fields[1]]={'app_file':fields[2],'private_dir':fields[3]}
 elif fields[0]=='MODULE':modules.append({'app':fields[1],'module':fields[2],'path':fields[3]})
 elif fields[0]=='PRIVATE':private.append({'app':fields[1],'path':fields[2]})
 elif fields[0]=='HELPER':helpers[fields[1]]=fields[2]
 elif fields[0]=='CLOSURE':closure=fields[1].split(',')
 elif fields[0]=='DEPS':dependencies[fields[1]]={'required':fields[2].split(',') if fields[2] else [],'included':fields[3].split(',') if fields[3] else [],'missing_optional':fields[4].split(',') if fields[4] else []}
record={'passed':False,'closure_replayed':False,'application_started':False,'domain_write':False,
 'retained_closure_producer_exit':old['true_child_exit'],'root_owner_command':command,
 'root_owner_exit':result.returncode,'root_owner_stdout':result.stdout.decode(),'root_owner_stderr':result.stderr.decode(),
 'actual_system_root':system_root}
def binding(path):
 if path.startswith('/work/'):
  n=path[len('/work/'):];r=restored['files'][n];p=stage/n
  assert p.is_file() and not p.is_symlink() and p.stat().st_size==r['bytes'] and p.stat().st_mode&0o7777==r['mode'] and h(p)==r['sha256']
 else:assert path.startswith(system_root+'/')
try:
 owned=['quod',*restored['qualified_dependency_app_names']]
 assert set(owned)|{'ssl','cowboy','gproc'}<=set(closure) and set(apps)==set(closure)
 for app,row in apps.items():
  binding(row['app_file'])
  if app in owned:assert row['app_file']=='/work/_build/prod/lib/'+app+'/ebin/'+app+'.app'
 for row in modules:
  if row['path']=='preloaded':assert row['app'] not in owned
  else:binding(row['path'])
  if row['app']=='quod':assert row['path'].startswith('/work/_build/prod/lib/quod/ebin/')
 for row in private:binding(row['path'])
 for name,path in helpers.items():assert path=='/work/_build/test/lib/quod/test/'+name+'.beam';binding(path)
 expected_private={('/work/'+n) for n in restored['files'] if any(n.startswith('_build/prod/lib/'+app+'/priv/') for app in owned)}
 assert {row['path'] for row in private}==expected_private
 assert any(row['module']=='quod_client_view' and row['path']=='/work/_build/prod/lib/quod/ebin/quod_client_view.beam' for row in modules)
 record.update(passed=True,closure=closure,applications=apps,modules=modules,private_resources=private,
  dependencies=dependencies,helpers=helpers,qualified_workspace_content_and_modes=True,
  production_quod_and_test_helper_precedence_verified=True,system_provider_image=old['command'][old['command'].index('--entrypoint')+2])
finally:
 cache=TASK/'cache/server-closure-verification02-hashes.json';d.write(cache)
 record['digest_cache']={'path':str(cache),'sha256':raw(cache),'hits':d.hits,'new_files':d.new,'new_bytes':d.bytes}
 (ev/'inputs/server-closure-verification02.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'passed':True,'closure_apps':len(closure),'declared_modules':len(modules),'private_resources':len(private),
 'system_root':system_root,'closure_replayed':False,'application_started':False}))
