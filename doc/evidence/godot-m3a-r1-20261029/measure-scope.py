#!/usr/bin/env python3
"""Count active physical lines, including new files, separately from relocation."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

evidence=Path(__file__).resolve().parent
root=evidence.parents[2]
output=evidence/sys.argv[1]
assert not output.exists()
groups={}
def category(name):
    if name.startswith(('src/','priv/','native/','client/')): return 'production'
    if name.startswith('test/'): return 'tests'
    if name.startswith('outdated/'): return 'archive'
    if name.startswith('doc/') and not name.startswith('doc/evidence/'): return 'specifications'
    if name=='nimbalyst-local/handoffs/godot-m3a-prompt.md': return 'preexisting-coordination'
    return None
def add(name,added,removed,kind):
    group=category(name)
    if group is None: return
    row=groups.setdefault(group,dict(added=0,removed=0,files=[]))
    row['added']+=added;row['removed']+=removed;row['files'].append(name)
    details[name]=dict(kind=kind,added=added,removed=removed,
        sha256=hashlib.sha256((root/name).read_bytes()).hexdigest() if (root/name).is_file() else None)
details={}
for line in subprocess.check_output(['git','diff','--numstat','HEAD'],cwd=root,text=True).splitlines():
    plus,minus,name=line.split('\t')
    assert plus!='-' and minus!='-',name
    add(name,int(plus),int(minus),'tracked change')
for name in subprocess.check_output(['git','ls-files','--others','--exclude-standard','-z'],cwd=root,text=True).split('\0'):
    if name and category(name) and (root/name).is_file() and not (root/name).is_symlink():
        add(name,len((root/name).read_bytes().splitlines()),0,'new file')
for row in groups.values(): row['net']=row['added']-row['removed']
result=dict(head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
    metric='Physical lines; all active new files included; evidence/generated/private stores excluded',
    groups=groups,files=details,
    framework_relocation=dict(gui_forms_existing_lines=289,geometry_schema_existing_lines=67,
        total_existing_lines=356,gui_forms_new_file_lines=297,geometry_schema_new_file_lines=93,
        new_file_overhead_lines=34,
        meaning='Already counted in active production +/-; relocation is not a reduction',
        prior_inputs=['preflight45-source.json','preflight46-source.json']),
    archived_original_lines=5)
output.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({name:{k:v for k,v in row.items() if k!='files'} for name,row in groups.items()}))
