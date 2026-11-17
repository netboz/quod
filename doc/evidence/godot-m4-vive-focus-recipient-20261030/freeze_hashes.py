"""Reuse accepted case12/root92 source custody without rereading old API bytes."""
import importlib.util,json,sys
from pathlib import Path
sys.dont_write_bytecode=True
old=Path(__file__).resolve().parent.parent/'godot-m4-vive-focus12-20261030/freeze_hashes.py'
before=list(sys.path)
try:
    sys.path.insert(0,str(old.parent))
    spec=importlib.util.spec_from_file_location('accepted_focus12_hashes',old)
    prior=importlib.util.module_from_spec(spec);spec.loader.exec_module(prior)
finally:sys.path[:]=before
Digests,TASK,key,raw,SOURCES=prior.Digests,prior.TASK,prior.key,prior.raw,prior.SOURCES
b=TASK/'artifacts/quod-godot-m4-vive-focus12-handoff-ca84d4f8-20261030-01'
assert raw(b/'snapshot.json')=='d3bf0febef580e1074017fdfdb249b2bc0c4183755fa38b695f0d4fe7d945625'
snapshot=json.loads((b/'snapshot.json').read_text())
for name in ['freeze-used-digests.json','reconstruction-used-digests.json']:
    SOURCES.append((b/name,snapshot['artifacts'][name]['sha256']))
SOURCES.append((TASK/'cache/coordinator-focus12-final92-hashes.json',
    '4adae6c63771ffdd73f19492389a501ff38d296d4fa3659b010b8ab2761dd7ce'))
