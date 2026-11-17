"""Compile affected current owners beside qualified dependencies; retain exits/EOF."""
from pathlib import Path
import hashlib,json,os,shutil,subprocess,sys,time
r=Path('/home/yan/src/quod_worktrees/pearl-stone');e=Path(__file__).resolve().parent
label=sys.argv[1];stage=Path('/data/quod-m4-vr-ca84d4f8-20261029/builds/answer-policy-clean-focused06/source')
p=r/'_build/stage2-presentation-boundaries'/label;p.mkdir(parents=True,exist_ok=False);(p/'ebin').mkdir()
source_names=[str(p.relative_to(r)) for p in (r/'src').rglob('*.erl')]
inputs={};expr=[];base={}
for obj in (stage/'_build/test/lib/quod/ebin').glob('*.beam'):
 shutil.copy2(obj,p/'ebin'/obj.name);base[obj.name]=hashlib.sha256(obj.read_bytes()).hexdigest()
for name in sorted(set(source_names)):
 src=r/name;dest=p/src.name;shutil.copy2(src,dest);inputs[name]={'sha256':hashlib.sha256(dest.read_bytes()).hexdigest(),'copy':str(dest)}
 expr.append('{ok,'+src.stem+'}=compile:file("/checks/'+src.name+'",[export_all,{d,\'TEST\'},{outdir,"/checks/ebin"},{i,"/code/include"},report_errors,report_warnings]),')
for src in (r/'include').glob('*.hrl'): inputs[str(src.relative_to(r))]={'sha256':hashlib.sha256(src.read_bytes()).hexdigest()}
expr+=['halt(0).']
args=['docker','run','--rm','--init','--user',str(os.getuid())+':'+str(os.getgid()),'-v',str(stage)+':/work:ro','-v',str(r)+':/code:ro','-v',str(p)+':/checks','-w','/code','-e','ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2','--entrypoint','/bin/sh','sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55','-c','exec erl -noshell -pa /work/_build/test/checkouts/*/ebin /work/_build/test/lib/*/ebin /work/_build/test/lib/quod/test -eval "$1"','sh','\n'.join(expr)]
start=time.monotonic();child=subprocess.run(args,capture_output=True)
(e/'logs'/(label+'-stdout.log')).write_bytes(child.stdout);(e/'logs'/(label+'-stderr.log')).write_bytes(child.stderr)
record={'compile_passed':child.returncode==0,'true_exit':child.returncode,'stdout_eof':True,'stderr_eof':True,'source_inputs':inputs,'base_objects':base,'ebin':str(p/'ebin'),'command':args,'elapsed_seconds':time.monotonic()-start}
(e/'inputs'/(label+'.json')).write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'compile_passed':record['compile_passed'],'exit':child.returncode,'elapsed':record['elapsed_seconds']}))
if child.returncode: print((child.stdout+child.stderr).decode(errors='replace')[-8000:])
sys.exit(child.returncode)
