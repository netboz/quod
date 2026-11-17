#!/usr/bin/env python3
"""Incremental development checks, explicitly separate from clean handoff gates."""
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

evidence = Path(__file__).resolve().parent
root = evidence.parents[2]
work = Path('/tmp/quod-m1a-dev-01')
label, *command = sys.argv[1:]
names = subprocess.check_output(
    ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=root
).decode().split('\0')
# Retired ontology files must not survive as a development compatibility path.
for old_source in (work / 'priv/ontologies').glob('*.pl'):
    if not (root / 'priv/ontologies' / old_source.name).exists():
        old_source.unlink()
manifest = {}
for name in names:
    if not name or not (name.startswith(('src/', 'include/', 'priv/', 'test/', 'config/', 'scripts/', 'native/', 'client/', 'ui/'))
                        or name in ['rebar.config', 'rebar.lock', 'README.md']):
        continue
    src = root / name
    if not src.is_file():
        continue
    dst = work / name
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    manifest[name] = hashlib.sha256(src.read_bytes()).hexdigest()
(evidence / 'inputs' / (label + '-incremental-inputs.json')).write_text(
    json.dumps({'incremental': True, 'reused_compiled_baseline': 'M0 campaign06', 'files': manifest}, indent=2) + '\n')
# Rebar uses source mtimes. An edit made while a prior staged build is
# compiling can otherwise be older than its resulting beam. Remove only this
# development stage's application/test beams; retained M0 stages are untouched.
docker = ['docker', 'run', '--rm', '--init', '--name', 'quod-m1a-' + label,
          '-v', str(work) + ':/work', '-v', str(evidence) + ':/evidence', '-w', '/work',
          '-e', 'ERL_FLAGS=+S 4:4 +SDio 2 +SDcpu 2', '-e', 'CARGO_HOME=/work/.cache/cargo',
          '-e', 'REBAR_CACHE_DIR=/work/.cache/rebar3',
          '-e', 'QUOD_M1A_EVIDENCE=/evidence/' + label + '-founding.json',
          '--entrypoint', '/bin/sh',
          'sha256:12c1389ee346993026ea83248037af7629f344eb2eebf09a6917ca0d10900e55',
          '-c', 'rm -f _build/test/lib/quod/ebin/*.beam _build/test/lib/quod/test/*.beam _build/default/lib/quod/ebin/*.beam; exec "$@"', 'm1a-dev-check']
result = subprocess.run([sys.executable, str(evidence / 'run.py'), '--timeout', '600', label, '--'] + docker + command,
                        cwd=root)
sys.exit(result.returncode)
