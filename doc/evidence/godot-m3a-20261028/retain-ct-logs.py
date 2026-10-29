#!/usr/bin/env python3
"""Retain sanitized Common Test text outputs; never enter fixture stores."""
import hashlib
import json
import os
from pathlib import Path
import re
import sys

evidence=Path(__file__).resolve().parent
root=evidence.parents[2]
label=sys.argv[1]
assert re.fullmatch(r'gates[0-9]{2}',label)
closed=json.loads((evidence/(label+'-result.json')).read_text())
assert closed['completed_gates'] and (closed['all_true_exits_zero'] or closed['unrun'])
source=root/'_build'/('m3a-'+label)/'source/_build/test/logs'
output=evidence/'logs'/(label+'-ct-details')
assert not output.exists()
output.mkdir()
rows={};excluded=[];metadata={}
for parent,dirs,files in os.walk(source,topdown=True,followlinks=False):
    current=Path(parent)
    for name in list(dirs):
        path=current/name
        if name=='log_private' or path.is_symlink():
            excluded.append(str(path.relative_to(source)));dirs.remove(name)
    for name in sorted(files):
        path=current/name
        relative=str(path.relative_to(source))
        if path.is_symlink():
            metadata[relative]=dict(kind='symlink',target=str(path.readlink()));continue
        data=path.read_bytes()
        raw_digest=hashlib.sha256(data).hexdigest()
        if path.suffix not in ('.html','.log','.css','.js','.txt','.xml','.json'):
            metadata[relative]=dict(kind='generated_binary_or_index',bytes=len(data),sha256=raw_digest);continue
        count=[0]
        def redact(match):
            numbers=re.findall(rb'\d+',match[0])
            if len(numbers) in (32,64) and all(int(v)<256 for v in numbers):
                count[0]+=1
                return (b'&lt;&lt;REDACTED_'+str(len(numbers)).encode()+b'_BYTE_BINARY&gt;&gt;' if match[0].startswith(b'&lt;') else b'<<REDACTED_'+str(len(numbers)).encode()+b'_BYTE_BINARY>>')
            return match[0]
        sanitized=re.sub(rb'(?:<<|&lt;&lt;)\s*(?:\d+\s*,\s*)*\d+\s*(?:>>|&gt;&gt;)',redact,data)
        destination=output/relative
        destination.parent.mkdir(parents=True,exist_ok=True)
        destination.write_bytes(sanitized)
        rows[relative]=dict(raw_sha256=raw_digest,sanitized_sha256=hashlib.sha256(sanitized).hexdigest(),
                            raw_bytes=len(data),sanitized_bytes=len(sanitized),redactions=count[0])
manifest=dict(campaign=label,raw_output_root=str(source),raw_outputs_retained_outside_public_snapshot=True,
    published_text_outputs=rows,excluded_private_subtrees=excluded,unpublished_generated_metadata=metadata,
    policy='Never enumerate/read log_private or follow directory symlinks. Retain complete nonprivate text outputs with the same byte-binary redaction as run.py. Raw text and generated indexes remain in the ignored closed stage.')
(evidence/'inputs'/(label+'-ct-log-outputs.json')).write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps(dict(campaign=label,text_outputs=len(rows),private_subtrees_excluded=len(excluded),
                     generated_metadata_entries=len(metadata),sanitized_bytes=sum(r['sanitized_bytes'] for r in rows.values()))))
