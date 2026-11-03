from pathlib import Path
import subprocess,json,hashlib,os,shutil
r=Path('/home/yan/src/quod_worktrees/pearl-stone');e=Path(__file__).resolve().parent
p=r/'_build/stage2-presentation-boundaries/carrier-fixture02';p.mkdir(exist_ok=False)
for f in (r/'_build/stage2-presentation-boundaries/admission-final01/ebin').glob('*.beam'):shutil.copy2(f,p/f.name)
names=['src/quod_scope_wire.erl','src/quod_signing_journal.erl','src/quod_dtx_phase_index.erl','src/predicates/quod_ask.erl','test/quod_scope_wire_tests.erl','test/quod_signing_journal_tests.erl','test/quod_dtx_phase_index_tests.erl','doc/evidence/stage2-presentation-boundaries-20261103/carrier_admission_checks.erl']

h=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()
names += ['test/fixtures/two-phase/qsj4-signing.b64']
inputs={n:h(r/n) for n in names}; inputs.update({str(f.relative_to(r)):h(f) for f in (r/'include').glob('*.hrl')})
for n in list(inputs):
 dest=p/'source'/n;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(r/n,dest)
inputs={n:h(p/'source'/n) for n in inputs}
expr='true=code:add_patha("/checks"),'+''.join('{ok,'+Path(n).stem+'}=compile:file("/checks/source/'+n+'",[export_all,{d,\'TEST\'},{outdir,"/checks"},{i,"/checks/source/include"},report_errors,report_warnings]),' for n in names if n.endswith('.erl'))+'case eunit:test(fun quod_signing_journal_tests:real_qsj4_is_refused_by_name_and_empty_qsj6_opens_test/0,[verbose]) of ok->halt(0);_->halt(1) end.'
stage='/data/quod-m4-vr-ca84d4f8-20261029/builds/answer-policy-clean-focused06/source'
args=['docker','run','--rm','--init','--user',str(os.getuid())+':'+str(os.getgid()),'-v',stage+':/work:ro','-v',str(r)+':/code:ro','-v',str(p)+':/checks','-w','/code','-e','ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2','--entrypoint','/bin/sh','sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55','-c','exec erl -noshell -pa /work/_build/test/checkouts/*/ebin /work/_build/test/lib/*/ebin /work/_build/test/lib/quod/test -eval "$1"','sh',expr]
x=subprocess.run(args,capture_output=True)
(e/'logs/carrier-fixture02-stdout.log').write_bytes(x.stdout);(e/'logs/carrier-fixture02-stderr.log').write_bytes(x.stderr)
(e/'inputs/carrier-fixture02.json').write_text(json.dumps(dict(command=args,true_exit=x.returncode,stdout_eof=True,stderr_eof=True,source_inputs=inputs),indent=2)+'\n')
print((x.stdout+x.stderr).decode(errors='replace'));print('TRUE_EXIT',x.returncode)
raise SystemExit(x.returncode)
