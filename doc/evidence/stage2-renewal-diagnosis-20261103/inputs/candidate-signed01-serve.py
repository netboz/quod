"""Disposable signed fixture on one coordinated current runtime snapshot."""
from pathlib import Path
import sys,os,json,hashlib,shutil,subprocess,time
R=Path.cwd(); E=Path(__file__).resolve().parent; label=sys.argv[1];build=sys.argv[2]
B=R/'_build/stage2-renewal-diagnosis'/build
receipt=json.loads((E/'inputs'/f'{build}.json').read_text()); assert receipt['true_exit']==0
h=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
for n,digest in receipt['source_inputs'].items():
 assert h(B/'source'/n)==digest,n
 if n.startswith(('src/','include/','priv/ontologies/','_build/default/lib/erlog/src/')):assert h(R/n)==receipt.get('base_inputs',{}).get(n,digest),n
P=R/'_build/stage2-renewal-diagnosis'/('server-'+label);P.mkdir(mode=0o700,exist_ok=False)
(P/'ebin').mkdir();(P/'tmp').mkdir()
factory=B/'source/test/quod_lifecycle_single_path_tests.erl'
s=factory.read_text();before='_ = file:del_dir_r(Dir),\n    ok.';assert s.count(before)==1
(P/factory.name).write_text(s.replace(before,'ok.'))
for n in ['serve.py','godot_m3b_fixture.erl']:
 shutil.copy2(E/n,E/'inputs'/(label+'-'+n))
 if n.endswith('.erl'):shutil.copy2(E/n,P/n)
expr='''
true=code:add_patha("/build/source/_build/default/lib/erlog/ebin"),
true=code:add_patha("/build/lib/quod/ebin"),
{ok,quod_lifecycle_single_path_tests}=compile:file("/m1b/quod_lifecycle_single_path_tests.erl",[debug_info,export_all,{outdir,"/m1b/ebin"},{i,"/build/source/include"}]),
{ok,godot_m3b_fixture}=compile:file("/m1b/godot_m3b_fixture.erl",[debug_info,{outdir,"/m1b/ebin"}]),
true=code:add_patha("/m1b/ebin"),
io:format("OWNER_BEAMS ~p~n",[[{M,code:which(M),M:module_info(md5)}||M<-[erlog_int,quod_prolog,quod_erlog_db_local_prove,quod_physics_tests]]]),
godot_m3b_fixture:start(),halt().
'''
stage='/data/quod-m4-vr-ca84d4f8-20261029/builds/answer-policy-clean-focused06/source'
cmd=['docker','run','--rm','-i','--init','--user',f'{os.getuid()}:{os.getgid()}','--network','host','--name','quod-renewal-'+label,'-v',stage+':/work:ro','-v',str(B)+':/build:ro','-v',str(P)+':/m1b','-v',str(P/'tmp')+':/tmp','-w','/build/source','-e','QUOD_M3B_PRIVATE=/m1b','-e','ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2','--entrypoint','/bin/sh','sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55','-c','exec erl -setcookie renewal_diagnosis_cookie -noshell -pa /work/_build/test/checkouts/*/ebin /work/_build/test/lib/*/ebin -eval "$1"','sh',expr]
record={'command':cmd,'build_receipt_sha256':h(E/'inputs'/f'{build}.json'),'build':build,'source_label':build,'candidate_only':receipt.get('candidate_only',False),'factory_before':h(factory),'factory_after':h(P/factory.name),'fixture_sha256':h(P/'godot_m3b_fixture.erl'),'raw_server_log':str(P/'server-raw.log'),'beams':{str(f.relative_to(B)):h(f) for base in [B/'lib/quod/ebin',B/'source/_build/default/lib/erlog/ebin'] for f in base.glob('*.beam')}}
(E/'inputs'/('server-'+label+'.json')).write_text(json.dumps(record,indent=2)+'\n')
x=subprocess.Popen(cmd,stdin=sys.stdin,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
with (P/'server-raw.log').open('xb') as log:
 for line in x.stdout:
  log.write(line);log.flush()
  if line.startswith(b'M1B_'):print(line.decode().rstrip(),flush=True)
x.wait();record.update(true_exit=x.returncode,merged_stream_eof=True)
(E/'inputs'/('server-'+label+'.json')).write_text(json.dumps(record,indent=2)+'\n')
raise SystemExit(x.returncode)
