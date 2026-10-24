from pathlib import Path
import difflib, hashlib, json, sys

root = Path('/home/yan/src/quod')
label = sys.argv[1]
evidence = root/'doc/evidence/world-library-20261016'
out = evidence/('review-'+label)
out.mkdir(exist_ok=False)
gate = evidence/('clean-integration-'+label)
tree = root/'_build/world-library-20261016'/('clean-integration-'+label)/'tree'
previous = root/'_build/world-library-20261016/clean-integration-02/tree'
manifest = json.loads((gate/'source-manifest.json').read_text())
assert all(hashlib.sha256((tree/n).read_bytes()).hexdigest() == h for n,h in manifest.items())
(out/'source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
patches=[]; counts={}
for n in manifest:
    before=(previous/n).read_bytes() if (previous/n).exists() else b''
    after=(tree/n).read_bytes()
    if before == after: continue
    try: a=before.decode().splitlines(True); b=after.decode().splitlines(True)
    except UnicodeDecodeError: raise RuntimeError('Changed binary review input: '+n)
    delta=list(difflib.unified_diff(a,b,fromfile='a/'+n,tofile='b/'+n))
    patches.extend(delta)
    if n.startswith(('src/','priv/ontologies/','native/','client/src/','ui/src/','include/')):
        counts[n]={'added':sum(l.startswith('+') and not l.startswith('+++') for l in delta),
                   'removed':sum(l.startswith('-') and not l.startswith('---') for l in delta)}
(out/'corrections.patch').write_text(''.join(patches))
(out/'production-delta.json').write_text(json.dumps({'files':counts,'added':sum(v['added'] for v in counts.values()),'removed':sum(v['removed'] for v in counts.values())},indent=2)+'\n')
print(json.dumps({'tree':str(tree),'manifest_entries':len(manifest),'production_delta':counts}))
