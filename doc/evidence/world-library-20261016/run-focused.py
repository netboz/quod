import datetime, hashlib, json, os, pathlib, subprocess, sys, time
root=pathlib.Path('/home/yan/src/quod')
label=sys.argv[1]; command=sys.argv[2:]
out=root/'doc/evidence/world-library-20261016'/label;out.mkdir(exist_ok=False)
paths=subprocess.check_output(['git','ls-files','-c','-o','--exclude-standard'],cwd=root,text=True).splitlines()
manifest={n:hashlib.sha256((root/n).read_bytes()).hexdigest() for n in sorted(set(paths)) if n.split('/')[0] in {'src','priv','native','client','ui','test','include'} and not n.startswith('priv/explorer/') and (root/n).is_file()}
(out/'source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
env=dict(os.environ,PATH='/home/yan/.asdf/shims:/home/yan/.cargo/bin:'+os.environ['PATH'],ERL_FLAGS='+S 4:4 +SDio 2 +SDcpu 2',CARGO_NET_OFFLINE='true')
for key in ['DEBUG','LD_LIBRARY_PATH','LD_PRELOAD']:env.pop(key,None)
started=datetime.datetime.now(datetime.timezone.utc).isoformat();t=time.monotonic()
with (out/'run.log').open('xb') as log:r=subprocess.run(command,cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT)
result={'command':command,'started':started,'exit':r.returncode,'seconds':round(time.monotonic()-t,2)}
(out/'receipt.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result),flush=True)
sys.exit(r.returncode)
