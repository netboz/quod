#!/usr/bin/env python3
"""Compare actual contents with the immutable M1b boundary, excluding phantom paths."""
import difflib
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path.cwd()
baseline = Path('/home/yan/.cache/quod-m1b-artifacts/quod-godot-m1b-handoff-1e4ef676-20261028-02')
before = {r['path']: r for r in json.loads((baseline / 'source-manifest.json').read_text())}
listed = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z']).decode().split('\0')
current = {n for n in listed if n and ((root/n).is_file() or (root/n).is_symlink())}
changes = []
preserved = {'m0_evidence': 0, 'm1a_evidence': 0, 'm1b_evidence': 0, 'archived_originals': 0}
def group(n):
    if n.startswith(('.agents/', 'nimbalyst-local/handoffs/', 'nimbalyst-local/plans/')): return 'coordination-and-generated'
    if n.startswith('doc/evidence/godot-m2-20261028/'): return 'm2-evidence'
    if n.startswith('priv/ontologies/'): return 'production-prolog'
    if n.startswith(('client/godot/tests/', 'client/godot-tests/', 'test/')): return 'tests-and-fixtures'
    if n.startswith('client/godot/') and n.endswith('.uid'): return 'generated-editor-metadata'
    if n.endswith('.md'): return 'specs-and-docs'
    if n.startswith('client/godot/') and n.endswith('.cs'): return 'production-client'
    if n.startswith('src/'): return 'production-runtime'
    if n.startswith('client/godot/'): return 'client-config-and-locks'
    if n.startswith('client/godot-tools/'): return 'build-tools'
    if n.startswith('outdated/'): return 'archive'
    return 'other'
for name in sorted(current | before.keys()):
    p = root/name
    row = before.get(name)
    same = row is not None and name in current and (
        (p.is_symlink() and row['kind']=='symlink' and str(p.readlink())==row['target']) or
        (not p.is_symlink() and row['kind']=='file' and hashlib.sha256(p.read_bytes()).hexdigest()==row['sha256']))
    if same:
        for category,prefix in [('m0_evidence','doc/evidence/godot-m0-20261027/'), ('m1a_evidence','doc/evidence/godot-m1a-20261027/'), ('m1b_evidence','doc/evidence/godot-m1b-20261028/'), ('archived_originals','outdated/ontologies/prolog/')]:
            if name.startswith(prefix): preserved[category] += 1
        continue
    item = {'path':name, 'group':group(name), 'change':'added' if row is None else 'deleted' if name not in current else 'modified'}
    try:
        a=(baseline/'source-tree'/name).read_text().splitlines() if row and row['kind']=='file' else []
        b=p.read_text().splitlines() if name in current and not p.is_symlink() else []
        added=removed=0
        for tag,i,j,k,l in difflib.SequenceMatcher(a=a,b=b,autojunk=False).get_opcodes():
            if tag in ('replace','delete'): removed += j-i
            if tag in ('replace','insert'): added += l-k
        item.update(added=added, removed=removed, delta=added-removed)
    except (UnicodeError,OSError): item['binary']=True
    changes.append(item)
totals={}
for row in changes:
    total=totals.setdefault(row['group'],dict(files=0,added=0,removed=0,delta=0));total['files']+=1
    for key in ('added','removed','delta'): total[key]+=row.get(key,0)
expected={category:sum(r['path'].startswith(prefix) for r in before.values()) for category,prefix in [('m0_evidence','doc/evidence/godot-m0-20261027/'),('m1a_evidence','doc/evidence/godot-m1a-20261027/'),('m1b_evidence','doc/evidence/godot-m1b-20261028/'),('archived_originals','outdated/ontologies/prolog/')]}
assert preserved==expected,preserved
result={'baseline':str(baseline), 'current_actual_files':len(current), 'preserved_unchanged':preserved,
        'groups':totals,'changes':changes,'relocations_in_m2':0,
        'note':'No M2 archive relocation or deletion is counted as reduction. Compiled/cache inputs are separate. The provisional reader incorrectly included nonexistent cached Git paths; this reader uses actual contents.'}
with (Path('doc/evidence/godot-m2-20261028/inputs')/('scope-delta-'+sys.argv[1]+'.json')).open('x') as file:
    file.write(json.dumps(result,indent=2)+'\n')
print(json.dumps({'preserved':preserved,'groups':totals}))
