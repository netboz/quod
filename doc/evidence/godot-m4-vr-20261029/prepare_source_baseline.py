"""One real cross-filesystem source materialization, for later delta proof."""
import hashlib,json,os,shutil
from pathlib import Path
from environment import TASK
prior=Path('/home/yan/.cache/quod-m4-observation1-artifacts/quod-godot-m4-observation1-handoff-ca84d4f8-20261029-01')
def h(p):
    with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
assert h(prior/'snapshot.json')=='b914f02fa049f5c8698f04e9b855228185224207771bc882d815d36cc1e7ed92'
baseline=prior.parent/(prior.name+'-complete-reconstruction')
out=TASK/'builds/complete-source-materialization01';out.mkdir(mode=0o700,exist_ok=False)
manifest=json.loads((prior/'source-manifest.json').read_text());total=sum(r.get('bytes',0) for r in manifest.values())
assert shutil.disk_usage(TASK).free>total+1024**3
assert baseline.stat().st_dev!=out.stat().st_dev
for name,row in manifest.items():
    original=baseline/name;target=out/name;target.parent.mkdir(parents=True,exist_ok=True)
    if row['kind']=='symlink':assert original.is_symlink() and str(original.readlink())==row['target'];target.symlink_to(row['target'])
    else:
        assert h(original)==row['sha256'] and original.stat().st_mode&0o7777==row['mode'],name
        shutil.copy2(original,target)
        assert h(target)==row['sha256'] and target.stat().st_mode&0o7777==row['mode'],name
        assert original.stat().st_dev!=target.stat().st_dev and original.stat().st_ino!=target.stat().st_ino
receipt={'previous_boundary':str(prior),'descriptor_sha256':h(prior/'snapshot.json'),'previous_materialized_source':str(baseline),'source_entries':len(manifest),'bytes':total,'new_materialization':str(out),'method':'Actual byte copies across distinct filesystems; every content/link/full recorded mode independently verified. No cross-device hardlinks or symbolic copies. One source materialization only, subsequently used for the final additive reconstruction proof.'}
(TASK/'artifacts/source-baseline-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt))
