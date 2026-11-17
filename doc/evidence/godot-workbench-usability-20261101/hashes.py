"""Existing exact-stat digest algorithm, authenticated accepted221 custody."""
import importlib.util
from pathlib import Path
p=Path(__file__).resolve().parent.parent/'godot-m4-presentation-20261030/digests.py'
s=importlib.util.spec_from_file_location('gui_digest_owner',p);prior=importlib.util.module_from_spec(s);s.loader.exec_module(prior)
prior.SOURCES=[(Path.cwd()/'_build/godot-m4-r2-coordinator-20261029/contextual-boundary-hashes-223.json','67f703942b59b9ae28107edcf029986aecfdd41b9031a2dd9defc9caf319cdfd')]
TASK,key,raw,Digests=prior.TASK,prior.key,prior.raw,prior.Digests
