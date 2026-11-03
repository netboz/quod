"""Authenticate sealed retest01 caches for additive source/output custody."""
import importlib.util,json,sys
from pathlib import Path
sys.dont_write_bytecode=True
old=Path(__file__).resolve().parent.parent/'godot-m4-vive-retest-20261030/freeze_hashes.py'
before_path=list(sys.path)
try:
    sys.path.insert(0,str(old.parent))
    spec=importlib.util.spec_from_file_location('prior_retest_freeze_hashes',old)
    prior=importlib.util.module_from_spec(spec);spec.loader.exec_module(prior)
finally:sys.path[:]=before_path
Digests,TASK,key,raw,SOURCES=prior.Digests,prior.TASK,prior.key,prior.raw,prior.SOURCES
boundary=TASK/'artifacts/quod-godot-m4-vive-retest-handoff-ca84d4f8-20261030-01'
assert raw(boundary/'snapshot.json')=='560ee1a4b1be5c01bac72d35318b4c2f2a4199e107ba9cf9870a87a9599dbcc4'
snapshot=json.loads((boundary/'snapshot.json').read_text())
for name in ['freeze-used-digests.json','reconstruction-used-digests.json']:
    SOURCES.append((boundary/name,snapshot['artifacts'][name]['sha256']))
SOURCES.append((TASK/'cache/coordinator-case10-83-hashes.json',
    '56a5c2f383868599ca06f7c09186dfe90274aa95654c7fda370ab0fc4f7ea484'))
SOURCES.append((TASK/'cache/coordinator-retest85-hashes.json',
    '3e8d661ce99c7af6a311bddb38ba3ea092b95586409a37b9b2db7486e1e04354'))
