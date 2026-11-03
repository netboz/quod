"""Compare actual OTP app-resource lookup before/after, without starting apps."""
import json,os,re,subprocess,sys
sys.dont_write_bytecode=True
from pathlib import Path
os.umask(0o077);ev=Path(__file__).resolve().parent
old=json.loads((ev/'inputs/server-runtime-restoration04.json').read_text());new=json.loads((ev/'inputs/server-runtime-restoration05.json').read_text());assert new['passed']
apps=['quod',*new['qualified_dependency_app_names']];assert all(re.fullmatch(r'[a-z][a-z0-9_]*',a) for a in apps)
app_list='['+','.join(apps)+']'
image='sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55'
expressions={
 'before':'R=code:where_is_file("gproc.app"),io:format("M4_APP_LOOKUP_BEFORE ~p~n",[R]),true=(R=:=non_existing),halt().',
 'after':'Apps='+app_list+',R=[{A,application:load(A)}||A<-Apps],io:format("M4_APP_LOOKUP_AFTER ~p~n",[R]),true=lists:all(fun({A,V})->V=:=ok orelse V=:={error,{already_loaded,A}} end,R),halt().'}
record={'application_started':False,'domain_write':False,'network':'none','stage_mount':'readonly','checks':{},'passed':False}
for label,stage in [('before',old['stage']),('after',new['stage'])]:
 command=['docker','run','--rm','--network','none','-v',stage+':/work:ro','-w','/work','--entrypoint','/bin/sh',image,
  '-c','exec erl -noshell -pa /work/_build/prod/lib/*/ebin /work/_build/test/lib/quod/test -eval "$1"','sh',expressions[label]]
 result=subprocess.run(command,capture_output=True,timeout=20)
 record['checks'][label]={'command':command,'true_child_exit':result.returncode,'stdout':result.stdout.decode(),'stderr':result.stderr.decode()}
 if result.returncode:break
record['passed']=len(record['checks'])==2 and all(r['true_child_exit']==0 for r in record['checks'].values())
(ev/'inputs/server-app-lookup-counterfactual01.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(record));raise SystemExit(0 if record['passed'] else 1)
