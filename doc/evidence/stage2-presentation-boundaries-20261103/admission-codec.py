from pathlib import Path
import subprocess,json,hashlib,os,shutil
r=Path('/home/yan/src/quod_worktrees/pearl-stone');e=Path(__file__).resolve().parent
p=r/'_build/stage2-presentation-boundaries/admission-codec01';p.mkdir(exist_ok=False)
for f in (r/'_build/stage2-presentation-boundaries/owner10/ebin').glob('*.beam'):shutil.copy2(f,p/f.name)
names=['src/'+m+'.erl' for m in ['quod_link','quod_safe_term','quod_wire_term','quod_client_goal','quod_client_goal_parser','quod_durable_term']]+['doc/evidence/stage2-presentation-boundaries-20261103/presentation_remaining_limits_tests.erl']
h=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
inputs={n:h(r/n) for n in names}
expr='true=code:add_patha("/checks"),'+''.join('{ok,'+Path(n).stem+'}=compile:file("/code/'+n+'",[export_all,{outdir,"/checks"},{i,"/code/include"},report_errors,report_warnings]),' for n in names)+'case eunit:test(presentation_remaining_limits_tests,[verbose]) of ok->halt(0);_->halt(1) end.'
stage='/data/quod-m4-vr-ca84d4f8-20261029/builds/answer-policy-clean-focused06/source'
args=['docker','run','--rm','--init','--user',str(os.getuid())+':'+str(os.getgid()),'-v',stage+':/work:ro','-v',str(r)+':/code:ro','-v',str(p)+':/checks','-w','/code','-e','ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2','--entrypoint','/bin/sh','sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55','-c','exec erl -noshell -pa /work/_build/test/checkouts/*/ebin /work/_build/test/lib/*/ebin -eval "$1"','sh',expr]
x=subprocess.run(args,capture_output=True)
(e/'logs/admission-codec01-stdout.log').write_bytes(x.stdout);(e/'logs/admission-codec01-stderr.log').write_bytes(x.stderr)
(e/'inputs/admission-codec01.json').write_text(json.dumps(dict(command=args,true_exit=x.returncode,stdout_eof=True,stderr_eof=True,source_inputs=inputs),indent=2)+'\n')
print((x.stdout+x.stderr).decode(errors='replace'));print('TRUE_EXIT',x.returncode)
raise SystemExit(x.returncode)
