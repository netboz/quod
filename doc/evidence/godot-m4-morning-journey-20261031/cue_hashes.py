"""Existing digest owner with qualified final06 exact-stat inputs and dependencies."""
import importlib.util
from pathlib import Path
p=Path(__file__).resolve().parent.parent/'godot-m4-workspace-20261030/hashes.py'
spec=importlib.util.spec_from_file_location('workspace_cue_digest_owner',p);prior=importlib.util.module_from_spec(spec);spec.loader.exec_module(prior)
Digests,TASK,key,raw,SOURCES=prior.Digests,prior.TASK,prior.key,prior.raw,prior.SOURCES
SOURCES.append((TASK/'artifacts/client-workspace-final06/computed-hashes.json','f4c741e571c17780b3bfc0312bac90558039c935a9a4c8d9771a1607439faeaf'))

SOURCES.append((TASK/'artifacts/client-placement-final01/computed-hashes.json','bbafb8430f950d76393f943b3c4006bb61150e7f51f4d24cd5b898cc48f83627'))
