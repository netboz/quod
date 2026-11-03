"""Complete declared OTP dependency/module/private-resource preflight; no starts."""
import json,os,subprocess,sys
sys.dont_write_bytecode=True
from pathlib import Path
from hashes import Digests,TASK,raw
os.umask(0o077);ev=Path(__file__).resolve().parent;d=Digests();h=d.h
restored=json.loads((ev/'inputs/server-runtime-restoration05.json').read_text());assert restored['passed']
info=restored['digest_cache'];assert raw(info['path'])==info['sha256']
for row in json.loads(Path(info['path']).read_text())['records']:
 k=tuple(row['stat_key']);assert k not in d.values or d.values[k]==row['sha256'];d.values[k]=row['sha256']
stage=Path(restored['stage']);owned=['quod',*restored['qualified_dependency_app_names']]
private={}
for app in owned:
 prefix='_build/prod/lib/'+app+'/priv/'
 private[app]=sorted(n[len(prefix):] for n in restored['files'] if n.startswith(prefix))
private_term='#{'+','.join(app+'=>['+','.join(json.dumps(n) for n in names)+']' for app,names in private.items())+'}'
seeds=list(dict.fromkeys([*owned,'ssl','cowboy','gproc']))
expression=r'''
Key=fun(A,K)->case application:get_key(A,K) of {ok,V}->V;undefined->[] end end,
Csv=fun(L)->string:join([atom_to_list(X)||X<-L],",") end,
Text=fun(V) when is_list(V)->V;(V) when is_atom(V)->atom_to_list(V);(V)->lists:flatten(io_lib:format("~p",[V])) end,
Private=PRIVATE_TERM,
Walk=fun F([],Seen,Issues)->{Seen,Issues};F([A|Rest],Seen,Issues)->
 case lists:member(A,Seen) of true->F(Rest,Seen,Issues);false->
  Loaded=application:load(A),
  case Loaded=:=ok orelse Loaded=:={error,{already_loaded,A}} of
   false->io:format("LOAD_ERROR\t~s\t~p~n",[atom_to_list(A),Loaded]),F(Rest,[A|Seen],[{A,resource}|Issues]);
   true->
    Name=atom_to_list(A),AppFile=code:where_is_file(Name++".app"),Priv=code:priv_dir(A),
    io:format("APP\t~s\t~s\t~s~n",[Name,Text(AppFile),Text(Priv)]),
    Optional=Key(A,optional_applications),Required=Key(A,applications)--Optional,Included=Key(A,included_applications),
    Present=[X||X<-Optional,code:where_is_file(atom_to_list(X)++".app")=/=non_existing],
    io:format("DEPS\t~s\t~s\t~s\t~s~n",[Name,Csv(Required),Csv(Included),Csv(Optional--Present)]),
    Modules=[{M,code:which(M)}||M<-Key(A,modules)],
    lists:foreach(fun({M,P})->io:format("MODULE\t~s\t~s\t~s~n",[Name,atom_to_list(M),Text(P)]) end,Modules),
    Missing=[M||{M,non_existing}<-Modules],
    PrivateNames=maps:get(A,Private,[]),
    BadPrivate=[N||N<-PrivateNames,not is_list(Priv) orelse not filelib:is_regular(filename:join(Priv,N))],
    lists:foreach(fun(N)->io:format("PRIVATE\t~s\t~s~n",[Name,filename:join(Text(Priv),N)]) end,PrivateNames),
    More=case Missing of []->Issues;_->[{A,{modules,Missing}}|Issues] end,
    More2=case BadPrivate of []->More;_->[{A,{private,BadPrivate}}|More] end,
    F(Rest++Required++Included++Present,[A|Seen],More2)
  end
 end end,
{Closure,Issues}=Walk(SEEDS,[],[]),
io:format("HELPER\tquod_lifecycle_single_path_tests\t~s~n",[Text(code:which(quod_lifecycle_single_path_tests))]),
io:format("HELPER\tquod_physics_tests\t~s~n",[Text(code:which(quod_physics_tests))]),
io:format("CLOSURE\t~s~n",[Csv(Closure)]),
io:format("ISSUES\t~p~n",[Issues]),true=(Issues=:=[]),halt().
'''.replace('PRIVATE_TERM',private_term).replace('SEEDS','['+','.join(seeds)+']')
image='sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55'
command=['docker','run','--rm','--network','none','-v',str(stage)+':/work:ro','-w','/work','--entrypoint','/bin/sh',image,
 '-c','exec erl -noshell -pa /work/_build/prod/lib/*/ebin /work/_build/test/lib/quod/test -eval "$1"','sh',expression]
result=subprocess.run(command,capture_output=True,timeout=30)
stdout=result.stdout.decode();stderr=result.stderr.decode();apps={};modules=[];resources=[];helpers={};closure=[];dependencies={}
record={'command':command,'true_child_exit':result.returncode,'application_started':False,'domain_write':False,
 'network':'none','mount':'readonly','passed':False,'stdout':stdout,'stderr':stderr}
try:
 assert result.returncode==0, 'OTP closure preflight failed'
 for line in stdout.splitlines():
  fields=line.split('\t')
  if fields[0]=='APP':apps[fields[1]]={'app_file':fields[2],'private_dir':fields[3]}
  elif fields[0]=='MODULE':modules.append({'app':fields[1],'module':fields[2],'path':fields[3]})
  elif fields[0]=='PRIVATE':resources.append({'app':fields[1],'path':fields[2]})
  elif fields[0]=='HELPER':helpers[fields[1]]=fields[2]
  elif fields[0]=='CLOSURE':closure=fields[1].split(',')
  elif fields[0]=='DEPS':dependencies[fields[1]]={'required':fields[2].split(',') if fields[2] else [],'included':fields[3].split(',') if fields[3] else [],'missing_optional':fields[4].split(',') if fields[4] else []}
 assert set(seeds)<=set(closure) and set(apps)==set(closure)
 for app in owned:assert apps[app]['app_file']=='/work/_build/prod/lib/'+app+'/ebin/'+app+'.app'
 for row in [*modules,*resources]:
  path=row['path']
  if path.startswith('/work/'):
   n=path[len('/work/'):];r=restored['files'][n];p=stage/n
   assert h(p)==r['sha256'] and p.stat().st_size==r['bytes'] and p.stat().st_mode&0o7777==r['mode']
  else:assert row in modules and (path=='preloaded' or path.startswith('/opt/erlang/'))
 for row in modules:
  if row['app']=='quod':assert row['path'].startswith('/work/_build/prod/lib/quod/ebin/')
 for name,path in helpers.items():
  assert path=='/work/_build/test/lib/quod/test/'+name+'.beam'
  n=path[len('/work/'):];assert h(stage/n)==restored['files'][n]['sha256']
 assert len(resources)==sum(len(v) for v in private.values())
 record.update(passed=True,closure=closure,applications=apps,dependencies=dependencies,modules=modules,
  private_resources=resources,helpers=helpers,production_quod_precedence_verified=True,
  test_helper_precedence_verified=True,qualified_workspace_module_bytes_verified=True,
  system_provider_identity=image)
finally:
 cache=TASK/'cache/server-closure-preflight01-hashes.json';d.write(cache)
 record['digest_cache']={'path':str(cache),'sha256':raw(cache),'hits':d.hits,'new_files':d.new,'new_bytes':d.bytes}
 (ev/'inputs/server-closure-preflight01.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'passed':True,'closure_apps':len(closure),'declared_modules':len(modules),'private_files':len(resources),
 'prod_quod_and_test_helper_precedence':True,'application_started':False,'domain_write':False}))
