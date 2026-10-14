import hashlib,json,pathlib,subprocess,time
root=pathlib.Path('/home/yan/src/quod');p=pathlib.Path(__file__).resolve().parent
manifest=json.loads((p/'manifest08.json').read_text())
for label,command in [('client-final',['npm','--prefix','client','test']),('build-final',['npm','--prefix','ui','run','build']),('server-final',['rebar3','eunit','--module=quod_gui_components_tests,quod_gui_question_tests,quod_gui_examples_tests,quod_lobby_tests,quod_reaction_authority_tests'])]:
 start=time.monotonic()
 with (p/(label+'.log')).open('x') as log: result=subprocess.run(command,cwd=root,stdout=log,stderr=subprocess.STDOUT)
 unchanged=all(hashlib.sha256((root/f).read_bytes()).hexdigest()==h for f,h in manifest.items())
 data=dict(exit=result.returncode,seconds=time.monotonic()-start,unchanged=unchanged)
 (p/(label+'.json')).write_text(json.dumps(data,indent=2)+'\n');print(label,data,flush=True)
 if result.returncode or not unchanged: raise SystemExit(1)
