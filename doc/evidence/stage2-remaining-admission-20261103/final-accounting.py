from pathlib import Path
import hashlib,json,difflib,subprocess,shutil
R=Path('/home/yan/src/quod_worktrees/pearl-stone');E=Path(__file__).resolve().parent
h=lambda b:hashlib.sha256(b).hexdigest()
main=json.loads((E/'proposals/manifest.json').read_text())['files'];ns=json.loads((E/'proposals/namespace-manifest.json').read_text())['files']
def data(p):return p.read_bytes() if p.exists() else b''
checks=[]
for n,v in main.items():
 assert h(data(R/n))==v['before'],n
 assert h(data(E/'proposal-after'/n))==v['after'],n
for n,v in ns.items():
 assert h(data(E/'proposal-after'/n) if n in main else data(R/n))==v['before'],n
 assert h(data(E/'namespace-after'/n))==v['after'],n
start=json.loads((E/'inputs/starting-source.json').read_text());changed=[n for n,v in start.items() if h(data(R/n))!=v];assert not changed,changed
(E/'inputs/production-unchanged-final02.json').write_text(json.dumps(dict(source_label='applied-carrier02',changed_since_start=changed,proposal_preimage_mismatches=[],production_delta=dict(added=0,removed=0)),indent=2)+'\n')
def category(n):
 if n.startswith('_build/default/lib/erlog/'):return 'dependency_tests' if '/test/' in n else 'dependency_production'
 if n.startswith('test/') or n.startswith('client/test/') or n.startswith('client/godot-tests/'):return 'tests'
 if n.startswith('doc/'):return 'specs'
 return 'repository_production'
def count(rows):
 out={}
 for n,(a,b) in rows.items():
  diff=list(difflib.unified_diff(a.decode().splitlines(True),b.decode().splitlines(True)))
  if not diff:continue
  c=out.setdefault(category(n),dict(files=0,added=0,removed=0,net=0));c['files']+=1
  c['added']+=sum(x.startswith('+') and not x.startswith('+++') for x in diff);c['removed']+=sum(x.startswith('-') and not x.startswith('---') for x in diff);c['net']=c['added']-c['removed']
 return out
m={n:(data(R/n),data(E/'proposal-after'/n)) for n in main}
s={n:(data(E/'proposal-after'/n) if n in main else data(R/n),data(E/'namespace-after'/n)) for n in ns}
combined={n:(data(R/n),data(E/('namespace-after' if n in ns else 'proposal-after')/n)) for n in set(main)|set(ns)}
delta=dict(main_proposal=count(m),namespace_increment=count(s),combined_from_current_source=count(combined),applied_production=dict(added=0,removed=0),note='Production includes TEST-only seams; tests/specs/dependency separate.')
(E/'inputs/proposal-delta02.json').write_text(json.dumps(delta,indent=2)+'\n')
# Only copy exact preimages to a plain applicability fixture. Never apply a patch.
base=R/'_build/stage2-remaining-admission/proposal-applicability02';base.mkdir(exist_ok=False)
for n,(a,_) in s.items():
 if a:
  p=base/n;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(a)
for name,cwd in [('remaining-owners.patch',R),('erlog-diagnostics.patch',R/'_build/default/lib/erlog'),('namespace-admission-CONDITIONAL.patch',base)]:
 patch=E/'proposals'/name;cmd=['git','apply','--check',str(patch)];p=subprocess.run(cmd,cwd=cwd,capture_output=True)
 checks.append(dict(patch=name,command=cmd,workdir=str(cwd),sha256=h(patch.read_bytes()),true_exit=p.returncode,stdout_eof=True,stderr_eof=True,stdout=p.stdout.decode(),stderr=p.stderr.decode(),applied=False))
(E/'inputs/apply-check04.json').write_text(json.dumps(checks,indent=2)+'\n');assert all(x['true_exit']==0 for x in checks),checks
print(json.dumps(delta,indent=2));print('ALL_PREIMAGES_AND_APPLICABILITY_PASS')
