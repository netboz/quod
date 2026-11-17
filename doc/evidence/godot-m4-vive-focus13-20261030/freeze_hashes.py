"""Accepted recipient97 post-link custody for the single authorized case13."""
import importlib.util,json,sys
from pathlib import Path
sys.dont_write_bytecode=True
old=Path(__file__).resolve().parent.parent/'godot-m4-vive-focus-recipient-20261030/freeze_hashes.py'
before=list(sys.path)
try:
    sys.path.insert(0,str(old.parent))
    spec=importlib.util.spec_from_file_location('accepted_recipient97_hashes',old)
    prior=importlib.util.module_from_spec(spec);spec.loader.exec_module(prior)
finally:sys.path[:]=before
Digests,TASK,key,raw,SOURCES=prior.Digests,prior.TASK,prior.key,prior.raw,prior.SOURCES
b=TASK/'artifacts/quod-godot-m4-vive-focus-recipient-handoff-ca84d4f8-20261030-01'
assert raw(b/'snapshot.json')=='2a31552df1860b7f0df312db7df83f9c1b639b17ef88bb5fe12a031a0a86ccf9'
snapshot=json.loads((b/'snapshot.json').read_text())
for name in ['freeze-used-digests.json','reconstruction-used-digests.json']:
    SOURCES.append((b/name,snapshot['artifacts'][name]['sha256']))
SOURCES.append((TASK/'cache/coordinator-focus-recipient-final97-hashes.json',
    '0065dc5bf54f6ac04dd5d50e8f988189f8a9fec6b15962346976ff0ace1aa8f1'))
# Failed01 remains unaccepted. These exact producer caches bind only byte
# custody and actual link-only transitions, independently checked against the
# unchanged accepted97 source and the actual partial materialization.
failed=TASK/'artifacts/quod-godot-m4-vive-focus13-handoff-ca84d4f8-20261030-01'
SOURCES.append((failed/'pre-reconstruction-digests.json','719479ab84e106122693ba687743d0c1ba9d3c6ec0cbe9f0cbb3db3189a662a3'))
SOURCES.append((failed/'source-link-transition-digests.json','b6ef72546b2b8ba08d7885e5082c8183d27a0c68471d17f81b943bf7dbda6378'))
