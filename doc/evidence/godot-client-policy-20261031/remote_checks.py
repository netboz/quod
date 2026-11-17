"""Compile only the corrected CT fixture against the qualified current test tree."""
import json,os,shutil,subprocess,sys
from pathlib import Path
from hashes import Digests,TASK,raw
os.umask(0o077);ev=Path(__file__).resolve().parent;root=Path.cwd();label=sys.argv[1]
stage=TASK/'private'/label;stage.mkdir(mode=0o700,exist_ok=False)
base=json.loads((ev/'answer-policy-clean-focused06-result.json').read_text())
assert base['all_true_exits_zero']
manifest=ev/'inputs/answer-policy-clean-focused06-source-manifest.json'
m=json.loads(manifest.read_text());work=Path(m['stage'])/'source';d=Digests()
assert all(d.h(root/n)==h==d.h(work/n) for n,h in m['files'].items()
           if n!='test/quod_ask_SUITE.erl')
suite=root/'test/quod_ask_SUITE.erl';shutil.copy2(suite,stage/suite.name)
(stage/'logs').mkdir()
expression='''{ok,quod_ask_SUITE}=compile:file("/input/quod_ask_SUITE.erl",[debug_info,{d,'TEST'},{i,"/work/include"},{outdir,"/input"},report_errors,report_warnings]),
R=ct:run_test([{dir,"/input"},{suite,quod_ask_SUITE},{testcase,answer_policy_producer_consumer_and_signed_change},{auto_compile,false},{logdir,"/input/logs"}]),
io:format("POLICY_CT_RESULT ~p~n",[R]),case R of {1,0,{0,0}}->halt(0);_->halt(1) end.'''
command=['docker','run','--rm','--network','none','--init','-v',str(work)+':/work:ro',
    '-v',str(stage)+':/input','-w','/input','-e','ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2',
    '-e','ERL_CRASH_DUMP=/input/erl_crash.dump','-e','XDG_CACHE_HOME=/input/cache',
    '--entrypoint','/bin/sh',m['image'],'-c',
    'exec erl -noshell -pa /work/_build/test/checkouts/*/ebin /work/_build/test/lib/*/ebin /work/_build/test/lib/quod/test /input -eval "$1"','sh',expression]
record={'command':command,'clean_manifest':str(manifest),'clean_manifest_sha256':raw(manifest),
    'suite_source':str(stage/suite.name),'suite_sha256':raw(stage/suite.name),
    'product_inputs_unchanged_from_focused105':True,'compiled_application_inputs_copied':False}
(ev/'inputs'/(label+'.json')).write_text(json.dumps(record,indent=2)+'\n')
r=subprocess.run(command)
record.update(true_child_exit=r.returncode,passed=r.returncode==0)
beam=stage/'quod_ask_SUITE.beam'
if beam.exists():record['suite_object']={'path':str(beam),'sha256':raw(beam),'bytes':beam.stat().st_size}
(ev/'inputs'/(label+'.json')).write_text(json.dumps(record,indent=2)+'\n')
raise SystemExit(r.returncode)
