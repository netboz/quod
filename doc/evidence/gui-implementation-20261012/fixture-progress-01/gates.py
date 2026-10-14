import pathlib,json,hashlib,subprocess,time
root=pathlib.Path('/home/yan/src/quod')
p=pathlib.Path(__file__).resolve().parent
manifest=json.loads((p/'manifest.json').read_text())
start=time.monotonic()
with (p/'server-gate01.log').open('x') as log:
 result=subprocess.run(['rebar3','eunit','--module=quod_gui_components_tests,quod_gui_question_tests,quod_gui_examples_tests,quod_lobby_tests'],cwd=root,stdout=log,stderr=subprocess.STDOUT)
unchanged=all(hashlib.sha256((root/f).read_bytes()).hexdigest()==h for f,h in manifest.items())
data=dict(exit=result.returncode,seconds=time.monotonic()-start,unchanged=unchanged)
(p/'server-gate01.json').write_text(json.dumps(data,indent=2)+'\n')
print(data,flush=True)
raise SystemExit(result.returncode if unchanged else 1)
