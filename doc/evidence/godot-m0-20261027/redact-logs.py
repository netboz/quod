#!/usr/bin/env python3
"""Preserve complete test logs except logged private-key tuples; never print keys."""
from pathlib import Path
import hashlib,json,os,re,sys
base=Path(__file__).resolve().parent
private=Path('/tmp/quod-m0-private-raw-logs-31de17b5')
private.mkdir(mode=0o700,exist_ok=True)
manifest=[]
paths=[base/name for name in sys.argv[1:]] if len(sys.argv)>1 else sorted((base/'logs').rglob('*.log'))
for p in paths:
    assert p.resolve().is_relative_to(base/'logs') and p.suffix=='.log'
    raw=p.read_text(errors='replace'); result=[]; at=0; count=0
    while True:
        m=re.search(r"\{\s*'ECPrivateKey'\s*,",raw[at:])
        if not m:result.append(raw[at:]);break
        start=at+m.start();depth=0;quote=None;escaped=False;end=None
        for i in range(start,len(raw)):
            c=raw[i]
            if escaped:escaped=False;continue
            if c=='\\':escaped=True;continue
            if quote:
                if c==quote:quote=None
                continue
            if c in "'\"":quote=c;continue
            if c=='{':depth+=1
            if c=='}':
                depth-=1
                if depth==0:end=i+1;break
        assert end is not None,('unbalanced private tuple',str(p))
        result.append(raw[at:start]);result.append('{redacted_private_key,disposable_test_identity}')
        # Preserve original line count for command/diagnostic references.
        result.append('\n'*raw[start:end].count('\n'));at=end;count+=1
    if count:
        relative=p.relative_to(base); saved=private/relative
        saved.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
        assert not saved.exists(),('already preserved',str(p))
        saved.write_bytes(p.read_bytes());saved.chmod(0o600)
        p.write_text(''.join(result))
        manifest.append(dict(path=str(relative),private_tuples_redacted=count,
                             original_sha256=hashlib.sha256(saved.read_bytes()).hexdigest(),
                             redacted_sha256=hashlib.sha256(p.read_bytes()).hexdigest()))
out=base/'log-redactions.json'
previous=json.loads(out.read_text()) if out.exists() else []
out.write_text(json.dumps(previous+manifest,indent=2)+'\n')
print('Redacted',sum(r['private_tuples_redacted'] for r in manifest),'disposable private-key tuples from',len(manifest),'logs; all other text and true exits retained.')
