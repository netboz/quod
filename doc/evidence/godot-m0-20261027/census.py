#!/usr/bin/env python3
"""Reproducible source census and conservative textual caller index (not dead-code proof)."""
import hashlib
import json
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[3]
out = Path(__file__).resolve().parent
def git(*args, cwd=root):
    return subprocess.check_output(['git', *args], cwd=cwd).decode()
def record(path):
    data = path.read_bytes()
    text = data.decode(errors='replace')
    # Explicit physical metric: exclude blank and whole comment lines only.
    lines = text.splitlines()
    return dict(path=str(path.relative_to(root)), sha256=hashlib.sha256(data).hexdigest(), bytes=len(data),
                physical_lines=len(lines), nonblank_noncomment_lines=sum(bool(s.strip()) and not s.lstrip().startswith(('%','//','#')) for s in lines))
tracked = git('ls-files').splitlines()
runtime = [p for p in tracked if p.startswith(('src/','include/','priv/ontologies/','config/','native/quod_physics/','scripts/'))
           or p in ['rebar.config','rebar.lock','Dockerfile','deploy/ci/Dockerfile','client/package-lock.json','client/native/Cargo.lock','ui/package-lock.json']]
(out/'runtime-manifest.json').write_text(json.dumps(dict(head=git('rev-parse','HEAD').strip(), branch=git('branch','--show-current').strip(), files=[record(root/p) for p in runtime]), indent=2)+'\n')
sources = sorted((root/'priv/ontologies').glob('*.pl'))
search_paths = [p for p in tracked if p.startswith(('src/','priv/ontologies/','test/','scripts/','config/','client/src/','client/test/','client/native/tools/','client/native/src/','ui/src/','deploy/')) and (root/p).is_file()]
texts = {p:(root/p).read_text(errors='replace').splitlines() for p in search_paths}
rows=[]
for source in sources:
    row=record(source); s=source.read_text()
    heads=sorted(set(re.findall(r'^([a-z][a-zA-Z0-9_]*)(?=\(|\s*\.)',s,re.M)))
    row['predicate_head_names']=heads
    row['explicit_file_callers']=[dict(path=p,line=i+1,text=line.strip()) for p,ls in texts.items() for i,line in enumerate(ls) if source.name in line and p != row['path']]
    row['vocabulary_pins']=sorted(set(re.findall(r'\b\w+_vocabulary\(',s)))
    # Name-based references can overcount same-name predicates. Keep provenance.
    names=set(heads)-{'isa','instance_of','attribute','have_attribute','can_invoke','can_join','acl_sovereign','action','constructor','class_permission','class_eidolon','eidolon','class_requirement'}
    pattern = re.compile(r'(?<![\w])(?:'+ '|'.join(re.escape(n) for n in sorted(names)) +r')\b') if names else None
    callers={}
    for p,ls in texts.items():
        if p==row['path']:continue
        hits=[i+1 for i,line in enumerate(ls) if pattern and pattern.search(line)]
        if hits:callers[p]=hits
    row['predicate_name_callers']=callers
    rows.append(row)
assert len(rows)==50,len(rows)
(out/'ontology-audit.json').write_text(json.dumps(dict(metric='nonblank_noncomment_lines excludes only blank and whole comment lines; not AST statements',sources=rows),indent=2)+'\n')
main=Path('/home/yan/src/quod')
dirty=git('diff','--name-only',cwd=main).splitlines()
delta=[]
for p in dirty:
    b=(main/p).read_bytes(); a=(root/p).read_bytes() if (root/p).exists() else b''
    category='browser' if p.startswith('client/') else 'planning' if p.startswith('nimbalyst-local/') else 'documentation' if p.startswith('doc/') else 'runtime-prerequisite' if p.startswith(('src/','include/','priv/','test/')) else 'unclassified'
    delta.append(dict(path=p,category=category,worker_sha256=hashlib.sha256(a).hexdigest(),main_sha256=hashlib.sha256(b).hexdigest()))
(out/'inputs/main-delta-manifest.json').write_text(json.dumps(dict(main_head=git('rev-parse','HEAD',cwd=main).strip(),main_branch=git('branch','--show-current',cwd=main).strip(),files=delta),indent=2)+'\n')
print(json.dumps(dict(sources=len(rows), physical_lines=sum(x['physical_lines'] for x in rows),nonblank_noncomment_lines=sum(x['nonblank_noncomment_lines'] for x in rows),runtime_files=len(runtime),main_delta_files=len(delta))))
