from pathlib import Path
import os,subprocess,json,time,datetime
p=Path(__file__).resolve().parent;r=p.parents[1];tree=r/'_build/quod27-release-263/gates-04/tree'
env={k:v for k,v in os.environ.items() if k not in ['LD_LIBRARY_PATH','LD_PRELOAD']};env['PATH']='/home/yan/.asdf/shims:'+env['PATH'];env['ERL_FLAGS']='+S 4:4 +SDcpu 2 +SDio 2'
commands=[('compile',['erlc','-o',str(p/'ebin')]+[str(p/n) for n in ['quod_physics_tests.erl','quod_space_tests.erl']]),('focused',['erl','-noshell','-pa']+[str(x) for x in sorted((tree/'_build/test/lib').glob('*/ebin'))]+[str(p/'ebin'),'-eval','case eunit:test([quod_physics_tests:ordinary_space_views_test_(),quod_physics_tests:numeric_geometry_and_hinge_refusals_test_(),quod_space_tests],[verbose]) of ok -> halt(0); _ -> halt(1) end.'])]
rows=[]
for name,cmd in commands:
 t=time.monotonic();started=datetime.datetime.now(datetime.timezone.utc).isoformat()
 with (p/(name+'.log')).open('x') as out:q=subprocess.run(cmd,cwd=tree,env=env,stdout=out,stderr=subprocess.STDOUT)
 row=dict(name=name,command=cmd,started=started,exit=q.returncode,seconds=time.monotonic()-t);rows.append(row);(p/'results.json').write_text(json.dumps(rows,indent=2)+'\n');print(json.dumps(row),flush=True)
 if q.returncode:(p/'STOP.json').write_text(json.dumps(row,indent=2)+'\n');raise SystemExit(q.returncode)
