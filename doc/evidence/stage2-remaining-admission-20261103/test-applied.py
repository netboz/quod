from pathlib import Path
import subprocess,json,hashlib,os,shutil,sys,time
R=Path('/home/yan/src/quod_worktrees/pearl-stone');E=Path(__file__).resolve().parent;label=sys.argv[1];spec=sys.argv[2]
if spec.startswith('@'):spec=(R/spec[1:]).read_text().strip()
build=os.getenv('APPLIED_BUILD','applied-build02');B=R/'_build/stage2-remaining-admission'/build;P=R/'_build/stage2-remaining-admission'/label;P.mkdir(exist_ok=False);(P/'source').symlink_to('/build/source')
assert json.loads((E/f'inputs/{build}.json').read_text())['true_exit']==0
Q=P/'lib/quod';(Q/'ebin').mkdir(parents=True);(Q/'test').mkdir();(Q/'priv').symlink_to('/build/source/priv')
D=P/'lib/erlog';shutil.copytree(B/'source/_build/default/lib/erlog/ebin',D/'ebin')
for name in ['src','test']:(D/name).symlink_to('/build/source/_build/default/lib/erlog/'+name)
test_names={f.stem for base in [B/'source/test',B/'source/_build/default/lib/erlog/test'] for f in base.glob('*.erl')}
for f in (B/'lib/quod/ebin').glob('*'):
 shutil.copy2(f,Q/('test' if f.stem in test_names else 'ebin')/f.name)
W=P/'work';W.mkdir();(P/'tmp').mkdir()
for name in ['src','test','include','priv']:(W/name).symlink_to('/build/source/'+name)
for name in ['rebar.config','rebar.lock']:shutil.copy2(B/'source'/name,W/name)
# The host fixture copies its own beam into the real application's ebin; keep
# test beams separate so this existing lifecycle does not copy a file onto itself.
expr='true=code:add_patha("/checks/lib/erlog/ebin"),true=code:add_patha("/checks/lib/quod/ebin"),true=code:add_patha("/checks/lib/quod/test"),io:format("OWNER_BEAMS ~p~n",[[{M,code:which(M)}||M<-[erlog_int,quod_prolog,quod_erlog_db_local_prove,quod_agent_hosting_tests]]]),case eunit:test('+spec+',[verbose]) of ok->halt(0);_->halt(1) end.'
stage='/data/quod-m4-vr-ca84d4f8-20261029/builds/answer-policy-clean-focused06/source'
args=['docker','run','--rm','--init','--user',f'{os.getuid()}:{os.getgid()}','-v',stage+':/work:ro','-v',str(B)+':/build:ro','-v',str(P)+':/checks','-v',str(P/'tmp')+':/tmp','-w','/checks/work','-e','ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2','--entrypoint','/bin/sh','sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55','-c','exec erl -setcookie stage2_validation_cookie -noshell -pa /work/_build/test/checkouts/*/ebin /work/_build/test/lib/*/ebin -eval "$1"','sh',expr]
h=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();beams={str(f.relative_to(P)):h(f) for f in (P/'lib').rglob('*.beam')};start=time.monotonic()
# Stream to retained logs while preserving true child exit and both EOF.
with (E/f'logs/{label}-stdout.log').open('wb') as out,(E/f'logs/{label}-stderr.log').open('wb') as err:
 child=subprocess.Popen(args,stdout=out,stderr=err);code=child.wait()
record=dict(command=args,true_exit=code,stdout_eof=True,stderr_eof=True,elapsed=time.monotonic()-start,source_label='applied-consolidated02-01',build_receipt=f'inputs/{build}.json',build_receipt_sha256=h(E/f'inputs/{build}.json'),runtime_beams=beams,test_spec=spec,private_fixture_path=str(P/'tmp'),user_stores_accessed=False)
(E/f'inputs/{label}.json').write_text(json.dumps(record,indent=2)+'\n');print('TRUE_EXIT',code,'ELAPSED',record['elapsed']);print((E/f'logs/{label}-stdout.log').read_text(errors='replace')[-1600:]);sys.exit(code)
