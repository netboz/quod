"""Accepted root104 post-link custody for the single authorized case14."""
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

b=TASK/'artifacts/quod-godot-m4-vive-focus13-handoff-ca84d4f8-20261030-02'
assert raw(b/'snapshot.json')=='b98c2ebf3f2085e0d75a4672f81965000e2b61c17de03f08c46faa137c81d6d9'
snapshot=json.loads((b/'snapshot.json').read_text())
for name in ['freeze-used-digests.json','reconstruction-used-digests.json']:
    if (b/name).exists():SOURCES.append((b/name,snapshot['artifacts'][name]['sha256']))
SOURCES.append((TASK/'cache/coordinator-focus13-final104-hashes.json',
 'ce50196ffcbf29778e60b8c3242a659c0fdb196258ba9da5edf573829e831afa'))

SOURCES.append((TASK/'artifacts/client-headset-cue01/computed-hashes.json','501cbc55c3bfe64f0b27f47947001aeabb870e24acd15bdb44efa4d8824fa98a'))
