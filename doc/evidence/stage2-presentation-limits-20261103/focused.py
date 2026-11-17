"""Affected real Prolog vocabulary and resource owners, qualified dependencies."""
import os,json,hashlib,subprocess,sys,shutil
from pathlib import Path
r=Path('/home/yan/src/quod_worktrees/pearl-stone');e=Path(__file__).resolve().parent;label=sys.argv[1]
p=r/'_build/stage2-presentation-limits'/label;p.mkdir(exist_ok=False);(p/'ebin').mkdir()
stage=Path('/data/quod-m4-vr-ca84d4f8-20261029/builds/answer-policy-clean-focused06/source');names=['src/quod_voxel.erl','src/quod_physics.erl','test/quod_rendering_tests.erl','test/quod_lens_tests.erl','test/quod_voxel_tests.erl']
modules='[quod_rendering_tests,quod_lens_tests,quod_voxel_tests]'
if '--reply' in sys.argv:
 names=['src/quod_wire_term.erl','src/quod_client_result.erl','src/quod_client_view.erl','src/quod_client_goal_endpoint.erl',str((e/'presentation_reply_checks.erl').relative_to(r))]
 modules='[presentation_reply_checks]'
if '--resources' in sys.argv:
 names=['src/quod_voxel.erl','src/quod_physics.erl',str((e/'presentation_resource_checks.erl').relative_to(r))]
 modules='[presentation_resource_checks]'
inputs={};expr=[]
for n in names:
 f=r/n;copy=p/f.name;shutil.copy2(f,copy);inputs[n]={'sha256':hashlib.sha256(copy.read_bytes()).hexdigest(),'copy':str(copy)}
 expr.append('{ok,'+f.stem+'}=compile:file("/checks/'+f.name+'",[export_all,{outdir,"/checks/ebin"},{i,"/code/include"},report_errors,report_warnings]),')
overlays=[]
for f in (r/'priv/ontologies').glob('*.pl'):
 copy=p/f.name;shutil.copy2(f,copy);inputs[str(f.relative_to(r))]={'sha256':hashlib.sha256(copy.read_bytes()).hexdigest(),'copy':str(copy)};overlays+=['-v',str(copy)+':/work/priv/ontologies/'+f.name+':ro']
expr+=['true=code:add_patha("/checks/ebin"), case eunit:test('+modules+',[verbose]) of ok->halt(0);_->halt(1) end.']
args=['docker','run','--rm','--init','--user',str(os.getuid())+':'+str(os.getgid()),'-v',str(stage)+':/work:ro','-v',str(r)+':/code:ro','-v',str(p)+':/checks','-w','/code','-e','ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2',*overlays,'--entrypoint','/bin/sh','sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55','-c','exec erl -noshell -pa /work/_build/test/checkouts/*/ebin /work/_build/test/lib/*/ebin /work/_build/test/lib/quod/test -eval "$1"','sh','\n'.join(expr)]
(e/'inputs'/(label+'.json')).write_text(json.dumps({'inputs':inputs,'command':args},indent=2)+'\n')
result=subprocess.run(['python3',str(r/'client/native/tools/check.py'),'--evidence',str(e/'logs'/label),'--',*args]);sys.exit(result.returncode)
