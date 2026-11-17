"""Affected world presentation owner; current source, retained local dependencies."""
import json,os,re,shutil,subprocess,sys
from pathlib import Path
from hashes import TASK,Digests,raw,key
os.umask(0o077);root=Path.cwd();ev=Path(__file__).resolve().parent;label=sys.argv[1]
stage=TASK/'private'/label;stage.mkdir(mode=0o700,exist_ok=False);(stage/'tmp').mkdir()
runtime=TASK/'builds/answer-policy-clean-focused06/source';d=Digests();inputs={}
names=['src/quod_client_view.erl','test/quod_lobby_tests.erl','priv/ontologies/common_predicates.pl','priv/ontologies/quod_space.pl',
       'include/quod_client_goal_limits.hrl','include/quod_directory_limits.hrl','include/quod_proof_limits.hrl','include/quod_ingress_limits.hrl']
for name in names:
    for header in re.findall(r'^-include\("([^\"]+)"\)',(root/name).read_text(),re.M):
        dependency='include/'+header
        if dependency not in names:names.append(dependency)
for name in names:
    p=root/name;q=stage/p.name;shutil.copy2(p,q);inputs[name]={'copy':str(q),'sha256':d.h(q),'original_stat_key':key(p),'mode':q.stat().st_mode};assert d.h(p)==inputs[name]['sha256']
shutil.copy2(Path(__file__),stage/'owner.py')
expression='''
{ok,quod_client_view}=compile:file("/stage/quod_client_view.erl",[report_errors,report_warnings,{outdir,"/stage"},{i,"/stage"}]),
{ok,quod_lobby_tests}=compile:file("/stage/quod_lobby_tests.erl",[report_errors,report_warnings,{outdir,"/stage"},{i,"/work/include"}]),
true=code:add_patha("/stage"),
case eunit:test([{generator,fun quod_lobby_tests:authored_space_composition_preserves_world_test_/0},
                {generator,fun quod_lobby_tests:inactive_physics_source_authoring_preserves_world_test_/0}],[verbose])
of ok->halt(0);error->halt(1) end.
'''
overlays=[]
for n in ['common_predicates.pl','quod_space.pl']:overlays+=['-v',str(stage/n)+':/work/priv/ontologies/'+n+':ro']
command=['docker','run','--rm','--network','none','--user',str(os.getuid())+':'+str(os.getgid()),
    '-v',str(runtime)+':/work:ro','-v',str(stage)+':/stage','-v',str(stage/'tmp')+':/tmp',*overlays,
    '-w','/stage','-e','ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2','--entrypoint','/bin/sh',
    'sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55','-c',
    'exec erl -noshell -pa /work/_build/test/checkouts/*/ebin /work/_build/test/lib/*/ebin /work/_build/test/lib/quod/test -eval "$1"','sh',expression]
r=subprocess.run(command)
record={'passed':r.returncode==0,'true_exit':r.returncode,'command':command,'inputs':inputs,
    'new_objects':{p.name:{'sha256':d.h(p),'bytes':p.stat().st_size} for p in stage.glob('*.beam')}}
d.write(stage/'computed-hashes.json');record['digest_cache']={'path':str(stage/'computed-hashes.json'),'sha256':raw(stage/'computed-hashes.json')}
(ev/'inputs'/(label+'.json')).write_text(json.dumps(record,indent=2)+'\n');raise SystemExit(r.returncode)
