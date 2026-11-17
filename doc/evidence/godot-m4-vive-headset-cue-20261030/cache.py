"""Use the existing digest owner with the accepted coordinator63 stat cache."""
import sys
sys.dont_write_bytecode=True
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent.parent/'godot-m4-presentation-20261030'))
from digests import Digests,SOURCES,TASK,key,raw
SOURCES.append((TASK/'cache/coordinator-charged63-hashes.json',
    '71455bf11364fd4b725c666f126ba569acac48c5b368796cd00aed3adfbe55a2'))

SOURCES.append((TASK/'cache/coordinator-focus13-final104-hashes.json','ce50196ffcbf29778e60b8c3242a659c0fdb196258ba9da5edf573829e831afa'))
