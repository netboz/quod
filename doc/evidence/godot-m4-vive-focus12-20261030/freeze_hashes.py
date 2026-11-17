"""Accepted failed11 post-link byte/source custody for distinct12."""
import importlib.util,json,sys
from pathlib import Path
sys.dont_write_bytecode=True
old=Path(__file__).resolve().parent.parent/'godot-m4-vive-focus11-20261030/freeze_hashes.py'
before=list(sys.path)
try:
    sys.path.insert(0,str(old.parent))
    spec=importlib.util.spec_from_file_location('failed11_custody',old)
    prior=importlib.util.module_from_spec(spec);spec.loader.exec_module(prior)
finally:sys.path[:]=before
Digests,TASK,key,raw,SOURCES=prior.Digests,prior.TASK,prior.key,prior.raw,prior.SOURCES
b=TASK/'artifacts/quod-godot-m4-vive-focus11-handoff-ca84d4f8-20261030-03'
assert raw(b/'snapshot.json')=='5e365156763eaefcd968fe7eaa1b3abc0f8044b0b5a203b534567e42dc592f9e'
snapshot=json.loads((b/'snapshot.json').read_text())
for name in ['freeze-used-digests.json','reconstruction-used-digests.json']:
    SOURCES.append((b/name,snapshot['artifacts'][name]['sha256']))
SOURCES.append((Path('/data/quod-m4-vr-ca84d4f8-20261029/cache/focus12-receipt-binding-hashes.json'),'04054e70d3502fe7335bd903f75ccbf6f19c847e057b7478459de1b9bd56a2f1'))
