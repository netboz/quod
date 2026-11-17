"""Use the existing digest owner with authenticated root104 stat custody."""
import importlib.util
from pathlib import Path
p=Path(__file__).resolve().parent.parent/'godot-m4-presentation-20261030/digests.py'
spec=importlib.util.spec_from_file_location('focus118_digest_owner',p);prior=importlib.util.module_from_spec(spec);spec.loader.exec_module(prior)
Digests,TASK,key,raw,SOURCES=prior.Digests,prior.TASK,prior.key,prior.raw,prior.SOURCES
SOURCES.append((TASK/'cache/coordinator-focus13-final104-hashes.json','ce50196ffcbf29778e60b8c3242a659c0fdb196258ba9da5edf573829e831afa'))
SOURCES.append((TASK/'artifacts/client-headset-cue01/computed-hashes.json','501cbc55c3bfe64f0b27f47947001aeabb870e24acd15bdb44efa4d8824fa98a'))

ROOT=Path('/home/yan/src/quod_worktrees/pearl-stone')
SOURCES += [(ROOT/'_build/godot-m4-r2-coordinator-20261029/xr-focus-software-hashes-119.json','1663d4756b92a02528d06af0fbd4aef06234952b5cc83e937eee2e34ca6ea1e1'),(ROOT/'_build/godot-m4-r2-coordinator-20261029/xr-focus-software-hashes-119-remaining02.json','a321e4452de1ebca2c885f9761c4f3abb4691ed35418b598d744b3f725ec67db'),(ROOT/'_build/godot-m4-r2-coordinator-20261029/xr-focus-seal-hashes-119.json','5b165dd8af7ca46ea7199ccf32bd49b18c3f2336b8d607f5acbb03aea3e3ebe7')]
