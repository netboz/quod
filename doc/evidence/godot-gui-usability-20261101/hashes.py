"""Existing exact-stat digest algorithm, authenticated accepted211 custody."""
import importlib.util
from pathlib import Path
p=Path(__file__).resolve().parent.parent/'godot-m4-presentation-20261030/digests.py'
s=importlib.util.spec_from_file_location('gui_digest_owner',p);prior=importlib.util.module_from_spec(s);s.loader.exec_module(prior)
prior.SOURCES=[(Path.cwd()/'_build/godot-m4-r2-coordinator-20261029/client-policy-seal-hashes-211-final02.json','cf41c969bfad5c34948d902d23ba2c52e744d2bd3842e8db0b276db885efd90c')]
TASK,key,raw,Digests=prior.TASK,prior.key,prior.raw,prior.Digests
