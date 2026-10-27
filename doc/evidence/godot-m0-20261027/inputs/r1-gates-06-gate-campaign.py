#!/usr/bin/env python3
"""Clean sequential local CI gates on exact frozen inputs; no Git worktree."""
import argparse,hashlib,json,os,shutil,subprocess,time
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('campaign');p.add_argument('--dependency-source');p.add_argument('--observe-acl',action='store_true');a=p.parse_args()
evidence=Path(__file__).resolve().parent;root=evidence.parents[2]
image='sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55'
stage=Path('/tmp')/('quod-m0-'+a.campaign)
stage.mkdir(mode=0o700,exist_ok=False)
work=stage/'source';work.mkdir()
(stage/'tmp').mkdir()
files=subprocess.check_output(['git','ls-files'],cwd=root).decode().splitlines()
selected=[n for n in files if n.startswith(('src/','include/','priv/','test/','config/','scripts/','client/','assets/','native/')) or n in ['rebar.config','rebar.lock','README.md','.forgejo/workflows/gates.yml','deploy/ci/Dockerfile']]
manifest={}
for name in selected:
 src=root/name
 if not src.is_file():continue
 dst=work/name;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dst)
 manifest[name]=hashlib.sha256(dst.read_bytes()).hexdigest()
# Reuse only locked dependency source inputs, never a compiled application or NIF.
dep_rows={}
dependency_source=Path(a.dependency_source).resolve() if a.dependency_source else root/'_build/default/lib'
for dep in sorted(dependency_source.iterdir()):
 if dep.name=='quod':continue
 dst=work/'_build/default/lib'/dep.name
 shutil.copytree(dep,dst,symlinks=True,ignore=shutil.ignore_patterns('.git','ebin','_build','.rebar3','target'))
 for f in sorted(dst.rglob('*')):
  if f.is_symlink():
   target=f.readlink()
   if target.is_absolute() or not f.resolve().is_relative_to(work):raise SystemExit('Dependency symlink escapes frozen source: '+str(f))
   dep_rows[str(f.relative_to(work))]={'symlink':str(target)}
  elif f.is_file():dep_rows[str(f.relative_to(work))]=hashlib.sha256(f.read_bytes()).hexdigest()
record=dict(campaign=a.campaign,stage=str(stage),image=image,head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root).decode().strip(),files=manifest,dependencies=dep_rows,compiled_inputs_copied=False,dependency_source=str(dependency_source),acl_observation=a.observe_acl)
(evidence/'inputs'/(a.campaign+'-source-manifest.json')).write_text(json.dumps(record,indent=2)+'\n')
(stage/'source-manifest.json').write_text(json.dumps(record,indent=2)+'\n')
gates=[('native',['cargo','test','--locked','--manifest-path','native/quod_physics/Cargo.toml'],900),
       ('eunit',['rebar3','as','test','eunit'],2400),
       ('ct',['rebar3','as','test','ct'],2400),
       ('xref',['rebar3','xref'],900),
       ('dialyzer',['rebar3','dialyzer'],1800)]
results=[]
try:
 for label,command,timeout in gates:
  name='quod-m0-31de17b5-'+a.campaign+'-'+label
  docker=['docker','run','--rm','--init','--name',name,
          '--volume',str(work)+':/work','--volume',str(stage/'tmp')+':/tmp',
          '--workdir','/work','--env','ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2',
          '--env','REBAR_CACHE_DIR=/work/.cache/rebar3',
          '--env','CARGO_HOME=/work/.cache/cargo',
          '--env','XDG_CACHE_HOME=/work/.cache/quod',
          '--entrypoint','/usr/bin/env',image]+command
  if label=='eunit' and a.observe_acl:
   at=docker.index('--entrypoint')
   docker[at:at]=['--volume',str(evidence)+':/m0:ro',
                 '--env','NODE_OPTIONS=--require=/m0/m0_fetch_diagnostic.cjs',
                 '--env','M0_HTTP_DIAGNOSTIC_DIRECTORY=/tmp']
  run=subprocess.run(['python3',str(evidence/'run.py'),'--timeout',str(timeout),a.campaign+'-'+label,'--']+docker,cwd=root)
  receipt=json.loads((evidence/'logs'/(a.campaign+'-'+label+'.json')).read_text())
  results.append(receipt)
  if run.returncode:break
finally:
 unchanged=all(hashlib.sha256((root/n).read_bytes()).hexdigest()==h and hashlib.sha256((work/n).read_bytes()).hexdigest()==h for n,h in manifest.items())
 summary=dict(campaign=a.campaign,image=image,source_unchanged=unchanged,completed_gates=len(results),required_gates=len(gates),all_true_exits_zero=len(results)==len(gates) and all(r['child_exit']==0 for r in results),results=results,unrun=[g[0] for g in gates[len(results):]])
 (evidence/(a.campaign+'-result.json')).write_text(json.dumps(summary,indent=2)+'\n')
 print(json.dumps({k:v for k,v in summary.items() if k!='results'}),flush=True)
 if not unchanged:raise SystemExit('Source changed during campaign; evidence invalid')
if not summary['all_true_exits_zero']:raise SystemExit(1)
