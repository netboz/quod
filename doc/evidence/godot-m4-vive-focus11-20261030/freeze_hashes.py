"""Authenticate accepted86 post-link custody before new additive evidence work."""
import importlib.util,json,sys
from pathlib import Path
sys.dont_write_bytecode=True
old=Path(__file__).resolve().parent.parent/'godot-m4-vive-retest10-20261030/freeze_hashes.py'
before=list(sys.path)
try:
    sys.path.insert(0,str(old.parent))
    spec=importlib.util.spec_from_file_location('accepted_retest10_hashes',old)
    prior=importlib.util.module_from_spec(spec);spec.loader.exec_module(prior)
finally:sys.path[:]=before
Digests,TASK,key,raw,SOURCES=prior.Digests,prior.TASK,prior.key,prior.raw,prior.SOURCES
SOURCES.append((TASK/'cache/coordinator-retest10-final86-hashes.json','a1c6e1b72b697cc47bfec27971bfb358731385748adffdf961fb76f423f635ba'))
SOURCES.append((Path('/data/quod-m4-vr-ca84d4f8-20261029/cache/focus11-receipt-binding-hashes.json'),'fbae0a7095b0378447bde6828673438b4cb39b6fd1ccd478c5b9a70de9ffc0b0'))
SOURCES.append((TASK/'artifacts/quod-godot-m4-vive-focus11-handoff-ca84d4f8-20261030-02/source-link-transition-digests.json','0dbe6ce1acb4682dfa2ec67ace55f073a5992cea47f7a8610fa910f115751db6'))
SOURCES.append((TASK/'artifacts/quod-godot-m4-vive-focus11-handoff-ca84d4f8-20261030-02/reconstruction-used-digests.json','43393d1211a40eea080e4e9c46e37dc42fa6b3820a38bbec9490714db7a8a2a1'))
SOURCES.append((TASK/'cache/coordinator-case11-88-hashes.json','17ecee9b74822fcb4cd058966c7a3a9d3c384e374a71a1a50e08d2f4c6a35e55'))
