"""Existing exact-stat digest algorithm, authenticated accepted228 custody."""
import importlib.util
from pathlib import Path
p=Path(__file__).resolve().parent.parent/'godot-m4-presentation-20261030/digests.py'
s=importlib.util.spec_from_file_location('gui_digest_owner',p);prior=importlib.util.module_from_spec(s);s.loader.exec_module(prior)
prior.SOURCES=[(Path('/data/quod-m4-vr-ca84d4f8-20261029/cache/coordinator-morning-package-boundary-228-hashes.json'),'f94020a73e3ecaed7f989dabc2a2af8d41861373377b6882cc8b80bacbcabe50')]
prior.SOURCES += [(Path('/data/quod-m4-vr-ca84d4f8-20261029/cache/coordinator-appearance-inspection-242-hashes.json'),'7fb45358cb570116fe887c6698aad29a04e1787b4866b34069e81fa371791f2b')]
TASK,key,raw,Digests=prior.TASK,prior.key,prior.raw,prior.Digests
