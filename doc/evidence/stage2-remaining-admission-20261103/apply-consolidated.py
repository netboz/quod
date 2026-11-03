from pathlib import Path
import json,hashlib,subprocess
R=Path('/home/yan/src/quod_worktrees/pearl-stone');E=Path(__file__).resolve().parent;P=R/'nimbalyst-local/review-packets/stage2-remaining-admission-proposal01';A=E/'application01';A.mkdir(exist_ok=False)
h=lambda b:hashlib.sha256(b).hexdigest()
auth=json.loads((E/'inputs/consolidated02-explicit-authorization02.json').read_text());assert auth['respondedAt']==1793723782653
freeze=json.loads((P/'result.json').read_text());m=json.loads((E/'proposals/manifest.json').read_text())['files'];ns=json.loads((E/'proposals/namespace-manifest.json').read_text())['files']
read=lambda p:p.read_bytes() if p.exists() else b''
for name,digest in freeze['patches'].items():assert h((E/'proposals'/name).read_bytes())==digest
for n,v in m.items():assert h(read(R/n))==v['before'],n
for n,v in ns.items():assert h(read(E/'proposal-after'/n) if n in m else read(R/n))==v['before'],n
for name,cwd in [('quod',R),('erlog',R/'_build/default/lib/erlog')]:
 for suffix,args in [('status',['git','status','--short']),('diff',['git','diff','--binary']),('head',['git','rev-parse','HEAD'])]:
  x=subprocess.run(args,cwd=cwd,capture_output=True);assert x.returncode==0;(A/f'{name}-before-{suffix}.txt').write_bytes(x.stdout)
rows=[]
for name,cwd in [('remaining-owners.patch',R),('namespace-admission-CONDITIONAL.patch',R),('erlog-diagnostics.patch',R/'_build/default/lib/erlog')]:
 for flag in ['--check',None]:
  cmd=['git','apply']+([flag] if flag else [])+[str(E/'proposals'/name)];x=subprocess.run(cmd,cwd=cwd,capture_output=True)
  row=dict(patch=name,sha256=freeze['patches'][name],command=cmd,workdir=str(cwd),true_exit=x.returncode,stdout_eof=True,stderr_eof=True,stdout=x.stdout.decode(),stderr=x.stderr.decode());rows.append(row);(A/'apply.json').write_text(json.dumps(rows,indent=2)+'\n');assert x.returncode==0,row
for n,v in (m|ns).items():
 if n in json.loads((E/'proposals/manifest.json').read_text()).get('deleted',[]):assert not (R/n).exists(),n
 else:assert h(read(R/n))==v['after'],n
(A/'result.json').write_text(json.dumps(dict(applied=True,source_label='applied-consolidated02-01',authorization_sha256=h((E/'inputs/consolidated02-explicit-authorization02.json').read_bytes()),patches=freeze['patches'],all_afterimages_match=True,files=len(m|ns),erlog_repository=str(R/'_build/default/lib/erlog'),erlog_pin_changed=False,committed=False),indent=2)+'\n')
p=R/'nimbalyst-local/plans/space-conceptual-architecture-review.md';s=p.read_text().replace('status: blocked','status: in-development',1);s+='\n\nConsolidated02 application01: explicit desktop authorization cell378 (respondedAt1793723782653) authorizes the exact three frozen patches and affected tests, including namespace format code. All preimages/afterimages match; source label applied-consolidated02-01. No store access/migration, pin change or commit. Affected owner validation is in progress; prior proposal freeze and original renewal failure remain literal. Parent owns subsequent reviewed Erlog publication/pin.\n';p.write_text(s)
print('APPLIED_EXACT_FROZEN_PATCHES',len(m|ns))
