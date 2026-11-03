from pathlib import Path
import subprocess,json,hashlib,os,shutil,sys
r=Path('/home/yan/src/quod_worktrees/pearl-stone');e=Path(__file__).resolve().parent;label=sys.argv[1]
p=r/'_build/stage2-remaining-admission'/label;p.mkdir(parents=True,exist_ok=False)
# Snapshot only; no generated beam is loaded or invoked.
for base in ['include','src','test','_build/default/lib/erlog/src','_build/default/lib/erlog/test']:
 for f in (r/base).rglob('*'):
  if f.suffix not in ['.erl','.hrl']:continue
  n=f.relative_to(r);s=e/'proposal-after'/n
  dest=p/'source'/n;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(s if s.exists() else f,dest)
for f in (e/'proposal-after').rglob('*'):
 if f.suffix in ['.erl','.hrl']:
  dest=p/'source'/f.relative_to(e/'proposal-after');dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(f,dest)
if os.getenv('PROPOSAL_NAMESPACE') == '1':
 for f in (e/'namespace-after').rglob('*'):
  if f.suffix in ['.erl','.hrl']:
   dest=p/'source'/f.relative_to(e/'namespace-after');dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(f,dest)
(p/'ebin').mkdir()
files=json.loads((e/'proposals/manifest.json').read_text())['files']
if os.getenv('PROPOSAL_NAMESPACE') == '1':files.update(json.loads((e/'proposals/namespace-manifest.json').read_text())['files'])
names=[n for n in files if n.endswith('.erl')]
# Record consumers must be rebuilt together; compiling never loads their beams.
for f in list((p/'source/src').rglob('*.erl')) + list((p/'source/_build/default/lib/erlog/src').rglob('*.erl')):
 if 'erlog_int.hrl' in f.read_text():names.append(str(f.relative_to(p/'source')))
names=sorted(set(names))
names=[n for n in names if n in sys.argv[2:]] if len(sys.argv)>2 else names
production=os.getenv('PROPOSAL_PRODUCTION')=='1'
if production:names=[n for n in names if not n.startswith('test/') and '/test/' not in n]
flags='' if production else '{d,list_to_atom("TEST")},export_all,'
header_check='{ok,Forms}=epp:parse_file("/checks/source/src/quod_erlog_db_local_prove.erl",["/checks/source/include","/checks/source/_build/default/lib","/checks/source/_build/default/lib/erlog/src"],[]),Headers=[F||{attribute,_,file,{F,_}}<-Forms],io:format("RESOLVED_HEADERS ~p~n",[Headers]),true=lists:member("/checks/source/_build/default/lib/erlog/src/erlog_int.hrl",Headers),'
header_check += '{ok,NativeForms}=epp:parse_file("/checks/source/_build/default/lib/erlog/src/erlog_int.erl",["/checks/source/_build/default/lib/erlog/src"],[]),[Record]=[R||{attribute,_,record,{est,_}=R}<-Forms],[Record]=[R||{attribute,_,record,{est,_}=R}<-NativeForms],io:format("SHARED_EST_RECORD ~p~n",[Record]),'
expr=header_check+'Results=[{N,compile:file("/checks/source/"++N,['+flags+'{outdir,"/checks/ebin"},{i,"/checks/source/include"},{i,"/checks/source/test"},{i,"/checks/source/_build/default/lib/erlog/src"},{i,"/checks/source/_build/default/lib"},report_errors,report_warnings])}||N<-'+json.dumps(names)+'],io:format("~p~n",[Results]),case lists:all(fun({_,{ok,_}})->true;(_)->false end,Results) of true->halt(0);false->halt(1) end.'
stage='/data/quod-m4-vr-ca84d4f8-20261029/builds/answer-policy-clean-focused06/source'
args=['docker','run','--rm','--init','--user',str(os.getuid())+':'+str(os.getgid()),'-v',stage+':/work:ro','-v',str(p)+':/checks','-w','/checks','-e','ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2','--entrypoint','/bin/sh','sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55','-c','exec erl -noshell -pa /work/_build/test/checkouts/*/ebin /work/_build/test/lib/*/ebin -eval "$1"','sh',expr]
x=subprocess.run(args,capture_output=True)
(e/f'logs/{label}-stdout.log').write_bytes(x.stdout);(e/f'logs/{label}-stderr.log').write_bytes(x.stderr)
h=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
(e/f'inputs/{label}.json').write_text(json.dumps(dict(command=args,true_exit=x.returncode,stdout_eof=True,stderr_eof=True,compiled_only=True,production_mode=production,proposed_modules_executed=False,source_inputs={str(f.relative_to(p/'source')):h(f) for f in (p/'source').rglob('*') if f.is_file()}),indent=2)+'\n')
print((x.stdout+x.stderr).decode(errors='replace'));print('TRUE_EXIT',x.returncode)
sys.exit(x.returncode)
