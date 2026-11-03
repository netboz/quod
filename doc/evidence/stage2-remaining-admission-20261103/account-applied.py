from pathlib import Path
import hashlib,json,difflib,subprocess
R=Path('/home/yan/src/quod_worktrees/pearl-stone');E=Path(__file__).resolve().parent
h=lambda b:hashlib.sha256(b).hexdigest()
read=lambda p:p.read_bytes() if p.is_file() else b''
main=json.loads((E/'proposals/manifest.json').read_text())['files'];ns=json.loads((E/'proposals/namespace-manifest.json').read_text())['files']
P=R/'_build/stage2-remaining-admission/applied-accounting01';P.mkdir(exist_ok=False)
for n in main.keys()|ns.keys():
 b=read(E/('namespace-after' if n in ns else 'proposal-after')/n)
 if b:p=P/n;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b)
receipts=[]
for name,cwd in [('namespace-admission-CONDITIONAL.patch',P),('remaining-owners.patch',P),('erlog-diagnostics.patch',P/'_build/default/lib/erlog')]:
 args=['git','apply','--reverse',str(E/'proposals'/name)];x=subprocess.run(args,cwd=cwd,capture_output=True)
 receipts.append(dict(command=args,workdir=str(cwd),purpose='Reconstruct immutable preimages in an accounting-only directory; no checkout edits',true_exit=x.returncode,stdout_eof=True,stderr_eof=True,stdout=x.stdout.decode(),stderr=x.stderr.decode()));assert x.returncode==0,receipts[-1]
for n,row in main.items():assert h(read(P/n))==row['before'],n
for n in ns.keys()-main.keys():assert h(read(P/n))==ns[n]['before'],n
extra={'src/quod_applied_certificate.erl':E/'before/src/quod_applied_certificate.erl','test/quod_foreign_projection_tests.erl':E/'application01/corrections07-before/test/quod_foreign_projection_tests.erl'}
for n,p in extra.items():q=P/n;q.parent.mkdir(parents=True,exist_ok=True);q.write_bytes(p.read_bytes())
def category(n):
 if n.startswith('_build/default/lib/erlog/'):return 'dependency_tests' if '/test/' in n else 'dependency_production'
 if n.startswith(('test/','client/test/','client/godot-tests/')):return 'tests'
 if n.startswith('doc/'):return 'specs'
 return 'repository_production'
counts={};files={};after_corrections={}
for n in sorted(main.keys()|ns.keys()|extra.keys()):
 a,b=read(P/n),read(R/n);d=list(difflib.unified_diff(a.decode().splitlines(True),b.decode().splitlines(True)))
 if not d:continue
 added=sum(x.startswith('+') and not x.startswith('+++') for x in d);removed=sum(x.startswith('-') and not x.startswith('---') for x in d)
 c=category(n);v=counts.setdefault(c,dict(files=0,added=0,removed=0,net=0));v['files']+=1;v['added']+=added;v['removed']+=removed;v['net']=v['added']-v['removed']
 files[n]=dict(before=h(a),after=h(b),added=added,removed=removed,category=c)
 if n in main or n in ns:
  frozen=read(E/('namespace-after' if n in ns else 'proposal-after')/n)
  if frozen!=b:after_corrections[n]=dict(frozen_after=h(frozen),current=h(b))
 else:after_corrections[n]=dict(extra_affected_caller=True,current=h(b))
start=json.loads((E/'inputs/starting-source.json').read_text());unexpected=[n for n,v in start.items() if h(read(R/n))!=v and n not in files];assert unexpected==[],unexpected
out=dict(source_label='applied-consolidated02-final01',baseline='exact consolidated02 preimages / applied-carrier02',categories=counts,files=files,post_proposal_corrections=after_corrections,unexpected_starting_product_changes=unexpected,accounting_reconstruction=receipts,note='Production includes TEST-only seams; inherited changes before this slice are excluded; no compression or coverage deletion to reduce count.')
(E/'application01/current-delta.json').write_text(json.dumps(out,indent=2)+'\n')
print(json.dumps(counts,indent=2))
