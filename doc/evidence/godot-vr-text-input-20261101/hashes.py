"""Existing exact-stat digest algorithm, authenticated accepted215 custody."""
import importlib.util
from pathlib import Path
p=Path(__file__).resolve().parent.parent/'godot-m4-presentation-20261030/digests.py'
s=importlib.util.spec_from_file_location('gui_digest_owner',p);prior=importlib.util.module_from_spec(s);s.loader.exec_module(prior)
prior.SOURCES=[(Path.cwd()/'_build/godot-m4-r2-coordinator-20261029/gui-boundary-hashes-215-corrected02.json','9196ced08844f5d8bb77f7602a209896306bbc54ac8635bb918af967f0f79b32')]
TASK,key,raw,Digests=prior.TASK,prior.key,prior.raw,prior.Digests
