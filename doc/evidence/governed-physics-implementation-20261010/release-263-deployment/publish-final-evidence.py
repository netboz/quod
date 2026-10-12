"""Seal public deployment and desktop receipts without private browser data."""
from pathlib import Path
import hashlib, json, shutil, tarfile

root = Path.cwd()
destination = root / 'doc/evidence/governed-physics-implementation-20261010'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def publish(source, name, excluded, copies):
    target = destination / name
    target.mkdir(exist_ok=False)
    files = [p for p in sorted(source.rglob('*')) if p.is_file()
             and not any(part in excluded for part in p.relative_to(source).parts)]
    manifest = [{'path': str(p.relative_to(source)), 'bytes': p.stat().st_size,
                 'sha256': digest(p)} for p in files]
    archive = target / 'evidence.tar.gz'
    with tarfile.open(archive, 'w:gz') as tar:
        for file in files:
            assert not file.is_symlink()
            tar.add(file, arcname=file.relative_to(source), recursive=False)
    with tarfile.open(archive) as tar:
        assert len(tar.getmembers()) == len(manifest)
        for row in manifest:
            data = tar.extractfile(row['path']).read()
            assert len(data) == row['bytes']
            assert hashlib.sha256(data).hexdigest() == row['sha256']
    receipt = {'count': len(files), 'bytes': sum(r['bytes'] for r in manifest),
               'excluded_names': sorted(excluded), 'archive_verified': True,
               'archive': {'path': archive.name, 'bytes': archive.stat().st_size,
                           'sha256': digest(archive)}, 'files': manifest}
    (target / 'files.json').write_text(json.dumps(receipt, indent=2) + '\n')
    for file in copies:
        shutil.copyfile(source / file, target / Path(file).name)
    print(json.dumps({'published': name, 'count': len(files),
                      'archive_bytes': archive.stat().st_size, 'sha256': digest(archive)}))

deployment = root / '_build/quod27-release-263/deployment'
assert json.loads((deployment / 'final-readback/PASSED.json').read_text())['passed']
publish(deployment, 'release-263-deployment',
        {'image-context', 'image-explorer', '__pycache__'},
        ['verified-image.json', 'source-commit.json', 'committed-inputs.json',
         'review-clearance.json', 'candidate-exact-diff.json', 'fleet-probe.json',
         'history-after.json', 'personal-owner-after.json', 'final-readback/PASSED.json'])
desktop = root / '_build/quod27-desktop-263-01'
assert json.loads((desktop / 'PASSED.json').read_text())['passed']
publish(desktop, 'desktop-263-01', {'__pycache__', 'session.json', 'chromedriver.log'},
        ['PASSED.json', 'analysis.json', 'acceptance-plan.json',
         'retained-view-identities.json', 'ordinary-reconnect-11-check.json',
         'browser-exit.json', 'verify-acceptance-03.exit.json',
         'console-read.png', 'opening-crossed-17.png', 'final-parked-19.png'])
