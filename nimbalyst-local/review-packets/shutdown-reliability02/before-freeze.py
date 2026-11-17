"""Archive only this checkpoint's new public evidence and verify real extraction."""
import hashlib, json, os, stat, subprocess, time
from pathlib import Path

os.umask(0o077)
root = Path.cwd()
packet = Path(__file__).resolve().parent
evidence = Path('doc/evidence/godot-shutdown-reliability-20261103')
reconstruction = root/'_build/godot-shutdown-reliability-20261103/reconstructed-delta01'
reconstruction.mkdir(exist_ok=False)
archive = packet/'new-evidence.tar.gz'
assert not archive.exists()
def digest(path):
    with path.open('rb') as f: return hashlib.file_digest(f, 'sha256').hexdigest()
def entry(path, base):
    s = path.lstat()
    row = {'path': str(path.relative_to(base)), 'mode': oct(stat.S_IMODE(s.st_mode))}
    if path.is_dir(): row['type'] = 'directory'
    else:
        assert path.is_file() and not path.is_symlink()
        row.update(type='file', bytes=s.st_size, sha256=digest(path))
    return row
paths = [root/evidence, *sorted((root/evidence).rglob('*'))]
entries = [entry(p, root) for p in paths]
manifest = {'scope': 'New public diagnostic/evidence subtree only; inherited source untouched; private profiles excluded.',
            'head': subprocess.check_output(['git', 'rev-parse', 'HEAD']).decode().strip(),
            'entries': entries, 'freeze_script_sha256': digest(Path(__file__))}
(packet/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
commands = []
for command in [['tar', '-czf', str(archive), '-C', str(root), str(evidence)],
                ['tar', '-xzf', str(archive), '-C', str(reconstruction)]]:
    started = time.monotonic()
    result = subprocess.run(command, capture_output=True)
    number = str(len(commands)+1)
    (packet/('command'+number+'-stdout.log')).write_bytes(result.stdout)
    (packet/('command'+number+'-stderr.log')).write_bytes(result.stderr)
    commands.append({'command': command, 'true_exit': result.returncode, 'elapsed_seconds': time.monotonic()-started})
    assert result.returncode == 0
actual = [entry(reconstruction/r['path'], reconstruction) for r in entries]
assert actual == entries
assert {str(p.relative_to(reconstruction)) for p in (reconstruction/evidence).rglob('*')} == {r['path'] for r in entries[1:]}
assert [entry(p, root) for p in paths] == entries
assert subprocess.check_output(['git', 'diff', '--binary', 'HEAD']) == (root/evidence/'inputs/baseline-tracked.patch').read_bytes()
result = {'passed': True, 'commands': commands, 'manifest_sha256': digest(packet/'manifest.json'),
          'archive_sha256': digest(archive), 'archive_bytes': archive.stat().st_size,
          'files': sum(r['type']=='file' for r in entries), 'directories': sum(r['type']=='directory' for r in entries),
          'reconstruction': str(reconstruction), 'contents_types_modes_verified': True,
          'inherited_changed_files': 0, 'production_lines_added': 0, 'production_lines_removed': 0}
(packet/'result.json').write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps(result))
