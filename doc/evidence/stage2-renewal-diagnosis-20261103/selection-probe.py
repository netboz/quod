from pathlib import Path
import os,sys,shutil,json,hashlib,subprocess,time
R=Path.cwd();E=Path(__file__).resolve().parent;label=sys.argv[1]
Base=R/'_build/stage2-renewal-diagnosis/configured-candidate01';P=R/'_build/stage2-renewal-diagnosis'/label
shutil.copytree(Base,P,symlinks=True)
base=json.loads((E/'inputs/configured-candidate01.json').read_text());inputs=dict(base['source_inputs']);changed=dict(base['base_inputs'])
name='src/quod_transaction_scope.erl';p=P/'source'/name;s=p.read_text();s=s.replace('-include("quod_proof_limits.hrl").','-include("quod_proof_limits.hrl").\n-include_lib("erlog/src/erlog_int.hrl").')
a='Tokens = quod_erlog_db_local_prove:live_transaction_tokens(St),';assert s.count(a)==1;s=s.replace(a,a+'\n            observe_selection(St, Lineage, Tokens),')
s+='''
observe_selection(#est{checkpoint_depth=Depth}, Lineage, Tokens) ->
    case persistent_term:get(stage2_selection_probe, undefined) of
        undefined -> ok;
        Table ->
            Key={Depth,Lineage=:=none,Tokens=:=[]},
            ets:update_counter(Table,Key,{2,1},{Key,0}),ok
    end.
'''
p.write_text(s);changed[name]=inputs[name];inputs[name]=hashlib.sha256(p.read_bytes()).hexdigest()
expr='true=code:add_patha("/build/source/_build/default/lib/erlog/ebin"),true=code:add_patha("/build/lib/quod/ebin"),true=is_map(erlog_int:new_bindings()),{ok,quod_transaction_scope}=compile:file("/build/source/src/quod_transaction_scope.erl",[debug_info,export_all,{d,\'TEST\'},{outdir,"/build/lib/quod/ebin"},{i,"/build/source/include"},{i,"/build/source/_build/default/lib"},report_errors]),halt(0).'
stage='/data/quod-m4-vr-ca84d4f8-20261029/builds/answer-policy-clean-focused06/source'
cmd=['docker','run','--rm','--init','--user',f'{os.getuid()}:{os.getgid()}','-v',stage+':/work:ro','-v',str(P)+':/build','-w','/build/source','-e','ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2','--entrypoint','/bin/sh','sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55','-c','exec erl -noshell -pa /work/_build/test/checkouts/*/ebin /work/_build/test/lib/*/ebin -eval "$1"','sh',expr]
t=time.monotonic();x=subprocess.run(cmd,capture_output=True)
for stream in ['stdout','stderr']:(E/'logs'/(label+'-'+stream+'.log')).write_bytes(getattr(x,stream))
record={'command':cmd,'true_exit':x.returncode,'stdout_eof':True,'stderr_eof':True,'elapsed':time.monotonic()-t,'source_inputs':inputs,'base_inputs':changed,'candidate_only':True,'instrumentation_only':True,'candidate_installed':False,'configuration_script_executed':True,'backend_asserted':'maps','parent':'configured-candidate01'}
(E/'inputs'/(label+'.json')).write_text(json.dumps(record,indent=2)+'\n');print((x.stdout+x.stderr).decode(errors='replace')[-2000:]);print('TRUE_EXIT',x.returncode);raise SystemExit(x.returncode)
