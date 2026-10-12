from pathlib import Path
import datetime,hashlib,json,tarfile,shutil,re
r=Path('/home/yan/src/quod');b=r/'_build/quod27-release-263/gates-05';p=r/'doc/evidence/governed-physics-implementation-20261010/release-263-gates-05'
passed=json.loads((b/'PASSED.json').read_text());assert passed['passed'] and passed['sources_unchanged'] and len(passed['results'])==11 and all(x['exit']==0 for x in passed['results'])
assert json.loads((b/'process-exit.json').read_text())['exit']==0
p.mkdir()
for x in b.iterdir():
 if x.is_file():shutil.copy2(x,p/x.name)
files={str(x.relative_to(b)):hashlib.sha256(x.read_bytes()).hexdigest() for folder in [b/'logs',b/'tree/_build/test/logs'] for x in sorted(folder.rglob('*')) if x.is_file()}
(p/'log-manifest.json').write_text(json.dumps(files,indent=2)+'\n')
with tarfile.open(p/'logs.tar.gz','w:gz') as a:
 for name in files:a.add(b/name,arcname=name)
for name in ['prepare-gates-05.py','run-gates-05.py','publish-gates-05.py']:shutil.copy2(b.parent/name,p/name)
eunit=re.sub(r'\x1b\[[0-9;]*m','',(b/'logs/eunit.log').read_text());counts=re.findall(r'(\d+) tests, (\d+) failures',eunit);assert counts and counts[-1][1]=='0',counts
(p/'README.md').write_text(f'''# Release 263 gate05 — all checks passed

All eleven gates passed sequentially against 1,036 frozen input files with true child exits and unchanged source hashes. Native debug/release each passed34 tests; clippy, client tests, UI build/lint, EUnit ({counts[-1][0]} tests /0 failures), Common Test (146 cases), xref, Dialyzer and production release packaging passed. Full logs and Common Test reports are archived with hashes.

This freeze includes the Opus5.5 implementation-review corrections and test-only lifecycle synchronization fixes. Gate04's two races and the standalone harness's missing-helper-path failure remain recorded separately. The final code uses one binary64 engine, with the verified upstream collision crate and minimal GJK correction; no compatibility implementation remains.

Source input files contain the proposed separate263 release label. Committed input attestation and exact image provenance are verified at the deployment boundary. Passing these gates alone is not signed desktop acceptance and does not close the task.
''')
print(json.dumps({'log_files':len(files),'archive_bytes':(p/'logs.tar.gz').stat().st_size,'eunit_tests':int(counts[-1][0])}))
