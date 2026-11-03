"""Run the affected fourteen existing parser obligations in a new output scope."""
import hashlib,sys
from pathlib import Path
sys.dont_write_bytecode=True
ev=Path(__file__).resolve().parent;prior=ev.parent/'godot-m4-vive-retest10-20261030'
source=prior/'focus_checks.py';fixture=prior/'focus-fixtures.json'
assert hashlib.sha256(source.read_bytes()).hexdigest()=='b36a2136611930d8ba8ddc4a08574cb953bffd0e4babbf2b9700f310f6b92738'
assert hashlib.sha256(fixture.read_bytes()).hexdigest()=='9a7381c85625a875726e9f229b0ce8b67b8695bb9dd41391679febf5f8f2a76a'
assert not (ev/'focus-fixtures.json').exists();(ev/'focus-fixtures.json').write_bytes(fixture.read_bytes())
sys.path.insert(0,str(prior))
# Only __file__ changes the result/fixture directory. The executed assertions
# are the exact retained source bytes; old evidence is never rewritten.
exec(compile(source.read_bytes(),str(source),'exec'),{'__file__':str(ev/'parser-cases.py'),'__name__':'__main__'})
