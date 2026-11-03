"""Finite new draft-compiler obligations through the existing Prolog owner."""
import json,os,shutil,subprocess,sys
from pathlib import Path
from hashes import TASK,raw
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent;label=sys.argv[1]
stage=TASK/'private'/label;stage.mkdir(mode=0o700,exist_ok=False)
inputs={}
catalogue=sys.argv[2:]==['--catalogue-only']
module='quod_lens_tests' if catalogue else 'workbench_checks'
for src in [root/'test/quod_lens_tests.erl' if catalogue else ev/'workbench_checks.erl',root/'priv/ontologies/gui_tools.pl']:
    dest=stage/src.name;shutil.copy2(src,dest);inputs[str(src.relative_to(root))]={'sha256':raw(dest),'copy':str(dest),'mode':dest.stat().st_mode}
qualified=json.loads((root/'doc/evidence/godot-space-stage2-20261031/inputs/stage2-owner-final02.json').read_text())
header=next(v for n,v in qualified['inputs'].items() if n.endswith('/erlog_int.hrl'));library=Path(header['copy']).parents[2]
runtime=TASK/'artifacts/server-runtime-restoration05'
test='fun quod_lens_tests:the_class_view_is_derived_test/0' if catalogue else 'fun workbench_checks:large_draft_uses_the_existing_bounded_chunk_owner_test/0' if sys.argv[2:]==['--large-only'] else 'fun workbench_checks:canonical_fact_identity_test/0' if sys.argv[2:]==['--identity-only'] else 'workbench_checks'
if sys.argv[2:]==['--matching-only']:
    test='['+','.join('fun workbench_checks:'+n+'/0' for n in ['remove_authored_fact_test','replace_authored_text_attribute_test','duplicate_and_missing_targets_refuse_test','unchanged_replacement_preserves_clause_order_test'])+']'
if sys.argv[2:]==['--saved-only']:test='fun workbench_checks:saved_fact_rule_spelling_test/0'
assert not sys.argv[2:] or sys.argv[2:] in [['--large-only'],['--catalogue-only'],['--identity-only'],['--matching-only'],['--saved-only']]
expression='{ok,'+module+'}=compile:file("/input/'+module+'.erl",[report_errors,report_warnings,{i,"/work/include"},{outdir,"/input"}]),case eunit:test('+test+',[verbose]) of ok->halt(0);error->halt(1) end.'
cmd=['docker','run','--rm','--network','none','--user',str(os.getuid())+':'+str(os.getgid()),'-v',str(runtime)+':/work:ro','-v',str(stage)+':/input','-w','/input','-v',str(stage/'gui_tools.pl')+':/work/_build/prod/lib/quod/priv/ontologies/gui_tools.pl:ro','-v',str(library)+':/compiler:ro','-e','ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2','-e','ERL_CRASH_DUMP=/input/erl_crash.dump','--entrypoint','/bin/sh','sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55','-c','exec erl -noshell -pa /work/_build/prod/lib/*/ebin /work/_build/test/lib/quod/test /compiler/erlog/ebin /input -eval "$1"','sh',expression]
obj=stage/(module+'.beam');r=subprocess.run(cmd);record={'command':cmd,'true_exit':r.returncode,'passed':r.returncode==0,'inputs':inputs,'new_object':{'sha256':raw(obj),'bytes':obj.stat().st_size} if obj.exists() else None,'existing_engine_owner':True,'functional_fixture':False,'hardware':False}
(ev/'inputs'/(label+'.json')).write_text(json.dumps(record,indent=2)+'\n');raise SystemExit(r.returncode)
