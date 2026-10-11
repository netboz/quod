import os,pathlib,subprocess,json,datetime,sys
p=pathlib.Path(__file__).resolve().parent
root=p.parent.parent
env=os.environ.copy();env.pop('LD_LIBRARY_PATH',None)
env['PATH']='/home/yan/.asdf/shims:/home/yan/.cargo/bin:'+env['PATH']
commands=[('eunit',['rebar3','eunit','--module=quod_effect_journal_tests,quod_root_resource_lifecycle_tests,quod_resource_lifecycle_tests,quod_lifecycle_single_path_tests,quod_node_context_tests,quod_client_result_tests,quod_scope_wire_tests,quod_proof_session_tests']),('client',['npm','--prefix','client','test'])]
for label,cmd in commands:
 start=datetime.datetime.now(datetime.timezone.utc).isoformat()
 with (p/(label+'.log')).open('wb') as log:
  child=subprocess.run(cmd,cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT)
 receipt={'command':cmd,'started':start,'finished':datetime.datetime.now(datetime.timezone.utc).isoformat(),'child_exit':child.returncode}
 (p/(label+'.json')).write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt),flush=True)
 if child.returncode:
  (p/'STOP.json').write_text(json.dumps(receipt,indent=2)+'\n');sys.exit(child.returncode)
