"""Existing digest owner plus authenticated coordinator63/65 source custody."""
import sys
sys.dont_write_bytecode=True
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent.parent/'godot-m4-presentation-20261030'))
from digests import Digests,SOURCES,TASK,key,raw
SOURCES.extend([(TASK/'cache/coordinator-charged63-hashes.json','71455bf11364fd4b725c666f126ba569acac48c5b368796cd00aed3adfbe55a2'),
 (TASK/'cache/coordinator-preparation65-hashes.json','78548db329df212148decc34ff5f8d2b643eff3bc7f723494ad53ed252830e82')])
