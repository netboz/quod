"""Compile only the affected symbol owners; exercise their existing pure seams."""
import argparse,hashlib,json,os,shutil,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('label');p.add_argument('--all',action='store_true');p.add_argument('--baseline',action='store_true');a=p.parse_args()
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent
task=Path('/data/quod-m4-vr-ca84d4f8-20261029');stage=task/'private'/a.label;stage.mkdir(mode=0o700,exist_ok=False)
def h(f):return hashlib.sha256(Path(f).read_bytes()).hexdigest()
inputs={}
names=['src/quod_wire_term.erl','src/quod_ontology_name.erl','src/quod_client_auth.erl','src/predicates/quod_ask.erl','test/quod_wire_term_tests.erl','test/quod_client_auth_tests.erl']
for name in names:
    src=(task/'private/stage2-owner-baseline01'/Path(name).name) if a.baseline and name.startswith('src/') else root/name
    copy=stage/src.name;shutil.copy2(src,copy);inputs[name]={'sha256':h(copy),'mode':copy.stat().st_mode,'copy':str(copy),'actual_source':str(src)}
runtime=task/'artifacts/server-runtime-restoration05'
header=root/'_build/default/lib/erlog/src/erlog_int.hrl'
assert h(header)=='fc2290033440d71447bb0b19eac04e81de1998438cfc225082e9200ac9595f20'
for src,dest in [(header,stage/'lib/erlog/src/erlog_int.hrl'),(runtime/'_build/prod/lib/erlog/ebin/erlog.app',stage/'lib/erlog/ebin/erlog.app')]:
    dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dest);inputs[str(src)]={'sha256':h(dest),'mode':dest.stat().st_mode,'copy':str(dest)}
(stage/'test').mkdir()
modules=['quod_wire_term','quod_ontology_name','quod_client_auth','quod_ask']
expression='true=code:add_patha("/stage/lib/erlog/ebin"),"/stage/lib/erlog"=code:lib_dir(erlog),\n'
for mod in modules:
    expression+=f'{{ok,{mod}}}=compile:file("/stage/{mod}.erl",[{{outdir,"/stage"}},{{i,"/work/include"}}]),\n'
expression+='{ok,quod_client_auth}=compile:file("/stage/quod_client_auth.erl",[{d,\'TEST\'},{outdir,"/stage/test"},{i,"/work/include"}]),\n'
for mod in ['quod_wire_term_tests','quod_client_auth_tests']:
    expression+=f'{{ok,{mod}}}=compile:file("/stage/{mod}.erl",[{{outdir,"/stage/test"}}]),\n'
expression+='true=code:add_patha("/stage"),true=code:add_patha("/stage/test"),\n'
tests='[quod_wire_term_tests,quod_client_auth_tests]' if a.all else 'fun quod_client_auth_tests:self_scoped_request_materializes_and_charges_callable_test/0'
expression+=f'case eunit:test({tests},[verbose]) of ok->halt(0);error->halt(1) end.'
command=['docker','run','--rm','--network','none','-v',str(runtime)+':/work:ro','-v',str(stage)+':/stage','-w','/stage','-e','ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2','--entrypoint','/bin/sh','sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55','-c','exec erl -noshell -pa /work/_build/prod/lib/*/ebin -eval "$1"','sh',expression]
record={'command':command,'inputs':inputs,'network':'none','functional_fixture':False,'module_suites':a.all,'passed':False}
try:
    child=subprocess.run(command);record['true_exit']=child.returncode;record['passed']=child.returncode==0
finally:
    record['new_objects']={f.name:{'sha256':h(f),'bytes':f.stat().st_size} for f in stage.glob('*.beam')}
    record['test_objects']={f.name:{'sha256':h(f),'bytes':f.stat().st_size} for f in (stage/'test').glob('*.beam')}
    (ev/'inputs'/(a.label+'.json')).write_text(json.dumps(record,indent=2)+'\n')
raise SystemExit(record['true_exit'])
