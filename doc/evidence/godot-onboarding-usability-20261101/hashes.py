"""Existing exact-stat digest algorithm, authenticated accepted218 custody."""
import importlib.util
from pathlib import Path
p=Path(__file__).resolve().parent.parent/'godot-m4-presentation-20261030/digests.py'
s=importlib.util.spec_from_file_location('gui_digest_owner',p);prior=importlib.util.module_from_spec(s);s.loader.exec_module(prior)
prior.SOURCES=[(Path.cwd()/'_build/godot-m4-r2-coordinator-20261029/vr-text-boundary-hashes-218.json','98a245800df9406d37488a40983c7ea444945fc33cbb700f7699d486023c961f')]
TASK,key,raw,Digests=prior.TASK,prior.key,prior.raw,prior.Digests
