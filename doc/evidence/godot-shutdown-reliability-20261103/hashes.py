import importlib.util
from pathlib import Path
p=Path(__file__).resolve().parent.parent/'godot-m4-presentation-20261030/digests.py'
s=importlib.util.spec_from_file_location('shutdown_digest_owner',p);prior=importlib.util.module_from_spec(s);s.loader.exec_module(prior)
prior.SOURCES=[(Path('/data/quod-m4-vr-ca84d4f8-20261029/cache/attention-package-qualified03-hashes.json'),'b6461a601edc14701b3b9fc5d4cdf2373fe1145f95174b75f48bf64323147374')]
TASK=Path(__file__).resolve().parents[3]/'_build/godot-shutdown-reliability-20261103'
key,raw,Digests=prior.key,prior.raw,prior.Digests
