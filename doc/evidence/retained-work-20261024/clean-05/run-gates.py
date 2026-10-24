import datetime,hashlib,json,os,pathlib,re,shutil,subprocess,sys,time
root=pathlib.Path('/home/yan/src/quod'); base=pathlib.Path('/tmp/quod-retained-work-20261024-05'); tree=base/'tree'; evidence=base/'evidence'
base.mkdir(exist_ok=False);tree.mkdir();evidence.mkdir()
tracked=subprocess.check_output(['git','ls-files','-z'],cwd=root).decode().split('\0')
extra=subprocess.check_output(['git','ls-files','--others','--exclude-standard','-z'],cwd=root).decode().split('\0')
roots={'src','include','priv','native','client','test','ui','scripts'}
inputs=sorted({n for n in tracked+extra if n and (root/n).is_file() and (n in tracked or n.split('/')[0] in roots or n=='doc/voxel-world.md')})
for n in inputs:
 dst=tree/n;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(root/n,dst)
manifest={n:hashlib.sha256((tree/n).read_bytes()).hexdigest() for n in inputs if not n.startswith('priv/explorer/')}
(evidence/'source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
(evidence/'freeze.json').write_text(json.dumps({'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'tree':str(tree),'frozen_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'purpose':'Review and commit retained source integrated with completed S1.1/S1.2. No deployment.'},indent=2)+'\n')
for dep in (root/'_build/default/lib').iterdir():
 if dep.name!='quod' and dep.is_dir(): shutil.copytree(dep,tree/'_build/default/lib'/dep.name,ignore=shutil.ignore_patterns('_build','*.beam'),symlinks=True)
for plt in (root/'_build/default').glob('*_plt*'):
 if plt.is_file():shutil.copy2(plt,tree/'_build/default'/plt.name)
for n in ['client/node_modules','ui/node_modules']: (tree/n).symlink_to(root/n,target_is_directory=True)
shutil.copytree(root/'native/quod_physics/target',tree/'native/quod_physics/target',symlinks=True)
env=dict(os.environ,PATH='/home/yan/.asdf/shims:/home/yan/.cargo/bin:'+os.environ['PATH'],ERL_FLAGS='+S 4:4 +SDio 2 +SDcpu 2',CARGO_NET_OFFLINE='true')
for k in ['DEBUG','LD_LIBRARY_PATH','LD_PRELOAD']:env.pop(k,None)
commands=[('agent-eunit',['rebar3','as','test','eunit','--module=quod_personal_agent_tests,quod_agent_custody_tests,quod_agent_hosting_tests','--verbose']),('xref',['rebar3','xref']),('dialyzer',['rebar3','dialyzer']),('release',['rebar3','as','prod','release'])]
def unchanged():return all((tree/n).is_file() and hashlib.sha256((tree/n).read_bytes()).hexdigest()==h for n,h in manifest.items())
patterns={'native-tests':r'test result: ok\. ([1-9][0-9]*) passed; 0 failed','native-release-tests':r'test result: ok\. ([1-9][0-9]*) passed; 0 failed','client-tests':r'CLIENT_TOTAL passed=([1-9][0-9]*) failed=0','agent-eunit':r'All ([1-9][0-9]*) tests passed\.','eunit':r'All ([1-9][0-9]*) tests passed\.','ct':r'All ([1-9][0-9]*) tests passed\.'}
results=[]
for name,args in commands:
 assert unchanged(),name
 print('Starting '+name,flush=True); start=time.monotonic()
 with (evidence/(name+'.log')).open('xb') as out:r=subprocess.run(args,cwd=tree,env=env,stdout=out,stderr=subprocess.STDOUT)
 row={'name':name,'command':args,'exit':r.returncode,'seconds':round(time.monotonic()-start,2),'sources_unchanged':unchanged()}
 if name in patterns:
  log=re.sub(r'\x1b\[[0-9;]*m','',(evidence/(name+'.log')).read_text());m=re.search(patterns[name],log);row['test_summary_complete']=m is not None
  if m:
   row['passed_tests']=int(m.group(1));row['test_summary_complete']=int(m.group(1)) >= {'native-tests':57,'native-release-tests':57,'client-tests':234,'agent-eunit':16,'eunit':4084,'ct':148}[name]
 if name=='ui-build' and not r.returncode:row['public_assets_preserved']=all((tree/'priv/explorer'/p.relative_to(tree/'ui/public')).read_bytes()==p.read_bytes() for p in (tree/'ui/public').rglob('*') if p.is_file())
 results.append(row);(evidence/'results.json').write_text(json.dumps(results,indent=2)+'\n');print(json.dumps(row),flush=True)
 if r.returncode or not row['sources_unchanged'] or row.get('test_summary_complete') is False or row.get('public_assets_preserved') is False:
  (evidence/'STOP.json').write_text(json.dumps(row,indent=2)+'\n');sys.exit(r.returncode or 1)
(evidence/'PASSED.json').write_text(json.dumps({'passed':True,'results':results},indent=2)+'\n')
