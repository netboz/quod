"""Freeze the independent Stage 2 audit; no application/build/release operation."""
import difflib
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
E = Path(__file__).resolve().parent
P = ROOT / 'nimbalyst-local/review-packets/stage2-d5-impact01'
P.mkdir(exist_ok=False)
PLAN = 'nimbalyst-local/plans/space-conceptual-architecture-review.md'
HANDOFF = 'nimbalyst-local/handoffs/stage2-d5-reconciliation-20261103.md'


def record(p):
    return {'sha256': hashlib.sha256(p.read_bytes()).hexdigest(),
            'bytes': p.stat().st_size, 'mode': p.stat().st_mode & 0o7777}


def run(label, args):
    p = subprocess.run(args, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    for suffix,data in [('stdout',p.stdout),('stderr',p.stderr)]:
        (P / (label+'-'+suffix+'.log')).write_bytes(data)
    r = {'label': label, 'command': args, 'child_exit': p.returncode,
         'stdout_eof': True, 'stderr_eof': True}
    (P / (label+'.json')).write_text(json.dumps(r,indent=2)+'\n')
    assert p.returncode == 0, r
    return r


def except_plan(patch):
    return b''.join(block for block in re.split(b'(?=^diff --git )',patch,flags=re.M)
                    if not block.startswith(('diff --git a/'+PLAN+' ').encode()))


checks = [run('diff-check', ['git','diff','--check'])]
assert except_plan(subprocess.check_output(['git','diff','--binary'],cwd=ROOT)) == except_plan((E/'starting-tracked.patch').read_bytes())
assert subprocess.check_output(['git','diff','--cached','--binary'],cwd=ROOT) == (E/'starting-index.patch').read_bytes()
before = json.loads((ROOT/'doc/evidence/stage2-d5-reconciliation-20261103/inherited-source.json').read_text())
for name, row in before.items():
    now = record(ROOT/name)
    assert all(now[k] == v for k,v in row.items()), name
prior = ROOT/'nimbalyst-local/review-packets/stage2-d5-reconciliation01/snapshot.tar'
assert record(prior)['sha256'] == '596ec74c0be816fea057ca655111c7ae3bdbab0fc39e600a1c5127b1691c0fe9'
text = (ROOT/PLAN).read_text()
checklist = text.split('## Implementation checklist',1)[1].split('## Implementation tickets',1)[0]
boxes = re.findall(r'^\s*- \[([ x])\]',checklist,re.M)
assert boxes.count('x') == 20 and len(boxes) == 25 and 'progress: 80\n' in text
for target in re.findall(r'\]\(([^)#]+)(?:#[^)]*)?\)',(ROOT/HANDOFF).read_text()):
    assert ((ROOT/HANDOFF).parent / target).is_file(), target

audit = json.loads((E/'audit-result.json').read_text())
for name,row in audit['current_source'].items():
    assert record(ROOT/name)['sha256'] == row['sha256'], name
for name,h in audit['evidence_bindings'].items():
    assert record(ROOT/name)['sha256'] == h, name
selected = {PLAN,HANDOFF,'AGENTS.md',*audit['current_source'],*audit['evidence_bindings'],
    'priv/ontologies/quod_user.pl','priv/ontologies/user_instance.pl','src/quod_committed_projection.erl'}
selected.update(str(p.relative_to(ROOT)) for p in E.rglob('*') if p.is_file())
manifest = {}
for name in sorted(selected):
    path=ROOT/name;target=P/'tree'/name
    target.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(path,target);manifest[name]=record(path)
    assert record(target)==manifest[name]
(P/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
checks.append(run('archive',['tar','-cf',str(P/'snapshot.tar'),'-C',str(P),'tree','manifest.json']))
restored=P/'reconstructed';restored.mkdir()
checks.append(run('extract',['tar','-xpf',str(P/'snapshot.tar'),'-C',str(restored)]))
assert json.loads((restored/'manifest.json').read_text())==manifest
assert {str(p.relative_to(restored/'tree')) for p in (restored/'tree').rglob('*') if p.is_file()}==set(manifest)
for name,row in manifest.items():assert record(restored/'tree'/name)==row,name
changes={}
for name in [PLAN,HANDOFF]:
    a=(E/'before'/name).read_text().splitlines();b=(ROOT/name).read_text().splitlines()
    added=removed=0
    for line in difflib.ndiff(a,b):
        added += line.startswith('+ ');removed += line.startswith('- ')
    changes[name]={'added':added,'removed':removed,'net':added-removed}
result={'kind':'stage2-independent-impact-and-caller-audit-freeze','files':len(manifest),
    'archive':record(P/'snapshot.tar'),'manifest':record(P/'manifest.json'),
    'reconstruction_verified':True,'checks':checks,'production_delta':'+0/-0',
    'document_delta_this_continuation':changes,'inherited_source_paths_unchanged':len(before),
    'prior_freeze_unchanged':record(prior),'index_and_inherited_tracked_changes_preserved':True,
    'new_runtime_runs':0,'new_runtime_qualification':False,'stage2_complete':False,
    'independent_work_complete':True,'remaining_decision':'D6 predicate/clause subject identity and layout; D7/Stage3 remain separate'}
(P/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
