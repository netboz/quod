"""Reuse current accepted workspace source/export stat custody."""
import importlib.util
from pathlib import Path
p=Path(__file__).resolve().parent.parent/'godot-m4-vive-workspace-cue-20261031/cue_hashes.py'
spec=importlib.util.spec_from_file_location('placement_digest_owner',p);prior=importlib.util.module_from_spec(spec);spec.loader.exec_module(prior)
Digests,TASK,key,raw,SOURCES=prior.Digests,prior.TASK,prior.key,prior.raw,prior.SOURCES
