import pathlib,subprocess,os,json,datetime,sys
p=pathlib.Path(__file__).resolve().parent
env=os.environ.copy();env.pop('LD_LIBRARY_PATH',None);env['PATH']='/home/yan/.asdf/shims:/home/yan/.cargo/bin:'+env['PATH']
start=datetime.datetime.now(datetime.timezone.utc).isoformat()
cmd=['rebar3','eunit','--module=quod_resource_lifecycle_tests']
with (p/'eunit.log').open('wb') as log:r=subprocess.run(cmd,env=env,stdout=log,stderr=subprocess.STDOUT)
receipt={'started':start,'finished':datetime.datetime.now(datetime.timezone.utc).isoformat(),'command':cmd,'child_exit':r.returncode}
(p/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt));sys.exit(r.returncode)
