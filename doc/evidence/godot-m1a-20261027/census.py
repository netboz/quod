#!/usr/bin/env python3
"""Separate active authored source, archived originals, tests and built assets."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
evidence = Path(__file__).resolve().parent
label = sys.argv[1]
head = subprocess.check_output(['git','rev-parse','HEAD'],cwd=root).decode().strip()
tracked = subprocess.check_output(['git','ls-tree','-r','--name-only','HEAD'],cwd=root).decode().splitlines()
current = sorted(set(subprocess.check_output(
    ['git','ls-files','--cached','--others','--exclude-standard','-z'],cwd=root).decode().split('\0')))

def contents(name, baseline):
    return (subprocess.check_output(['git','show','HEAD:'+name],cwd=root) if baseline
            else (root/name).read_bytes())

def count(names, baseline=False):
    files = []
    for name in names:
        raw = contents(name,baseline)
        lines = raw.decode(errors='replace').splitlines()
        files.append(dict(path=name,bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest(),
                          physical_lines=len(lines),
                          nonblank_noncomment=sum(bool(s.strip()) and not s.lstrip().startswith(('%','//')) for s in lines)))
    return dict(files=len(files),physical_lines=sum(f['physical_lines'] for f in files),
                nonblank_noncomment=sum(f['nonblank_noncomment'] for f in files),
                bytes=sum(f['bytes'] for f in files),manifest=files)

categories = {
    'active_prolog': lambda n:n.startswith('priv/ontologies/') and n.endswith('.pl'),
    'runtime_erlang': lambda n:n.startswith('src/') and n.endswith('.erl'),
    'client_authored': lambda n:n.startswith(('client/src/','ui/src/')) and n.endswith(('.js','.jsx','.ts','.tsx')),
    'test_erlang': lambda n:n.startswith('test/') and n.endswith('.erl'),
    'test_prolog_fixtures': lambda n:n.startswith('test/') and n.endswith('.pl'),
    'packaged_browser_derived': lambda n:n.startswith('priv/explorer/'),
}
result = dict(head=head,metric='Physical lines and nonblank/non-whole-comment lines; not AST statements.',categories={})
for category, select in categories.items():
    before = count([n for n in tracked if select(n)],True)
    after = count([n for n in current if select(n) and (root/n).is_file()])
    delta = {k:after[k]-before[k] for k in ['files','physical_lines','nonblank_noncomment','bytes']}
    result['categories'][category] = dict(base=before,current=after,delta=delta)
archives = count([n for n in current if n.startswith('outdated/ontologies/prolog/') and n.endswith('.pl')])
for f in archives['manifest']:
    original = 'priv/ontologies/'+Path(f['path']).name
    assert original in tracked and not (root/original).exists(), original
    assert f['sha256'] == hashlib.sha256(contents(original,True)).hexdigest(), original
    f['original_path'] = original
result['archives'] = archives
result['archive_originals_verified'] = True
result['archive_relocation_is_code_reduction'] = False
result['erlang_ontology_archives'] = 0
result['active_prolog_paths'] = [f['path'] for f in result['categories']['active_prolog']['current']['manifest']]
output = evidence / (label+'-line-accounting.json')
if output.exists(): raise SystemExit('Keep prior measurements; choose a fresh label')
output.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(dict(active_prolog={k:v for k,v in result['categories']['active_prolog']['current'].items() if k!='manifest'},
                     active_prolog_delta=result['categories']['active_prolog']['delta'],
                     archive_files=archives['files'],archive_lines=archives['physical_lines'])))
