"""Use the existing digest owner with authenticated root104 stat custody."""
import importlib.util
from pathlib import Path
p=Path(__file__).resolve().parent.parent/'godot-m4-presentation-20261030/digests.py'
spec=importlib.util.spec_from_file_location('focus118_digest_owner',p);prior=importlib.util.module_from_spec(spec);spec.loader.exec_module(prior)
Digests,TASK,key,raw,SOURCES=prior.Digests,prior.TASK,prior.key,prior.raw,prior.SOURCES
SOURCES.append((TASK/'cache/coordinator-focus13-final104-hashes.json','ce50196ffcbf29778e60b8c3242a659c0fdb196258ba9da5edf573829e831afa'))
SOURCES.append((TASK/'artifacts/client-headset-cue01/computed-hashes.json','501cbc55c3bfe64f0b27f47947001aeabb870e24acd15bdb44efa4d8824fa98a'))
