from pathlib import Path
import hashlib
import json
import os
import shutil


root = Path('/home/yan/src/quod_worktrees/pearl-stone')
dist = root / 'client/godot/dist'
installed = Path('/home/yan/Games/quod')
stage = Path('/home/yan/Games/quod-eidolon-stage-20261116')
backup = Path('/home/yan/Games/quod-before-eidolon-20261116')
receipt = root / 'doc/evidence/interior-eidolon-release-20261116/client-install01.json'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


if stage.exists() or backup.exists() or receipt.exists():
    raise SystemExit('Refusing to overwrite stage, rollback copy, or receipt')
if installed.is_symlink() or not installed.is_dir():
    raise SystemExit('Unexpected installation layout')

active = []
for process in Path('/proc').iterdir():
    if not process.name.isdecimal():
        continue
    try:
        executable = (process / 'exe').resolve(strict=True)
        if executable.is_relative_to(installed):
            active.append(int(process.name))
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        pass
if active:
    raise SystemExit('Installed Quod is running: ' + str(active))

shutil.copytree(dist, stage)
for name in ['steam', 'last-run.log']:
    source = installed / name
    if source.is_dir():
        shutil.copytree(source, stage / name)
    elif source.is_file():
        shutil.copy2(source, stage / name)
shutil.copy2(root / 'client/godot-tools/package/quod', stage / 'quod')

hashes = {
    str(path.relative_to(dist)): digest(path)
    for path in dist.rglob('*')
    if path.is_file()
}
for relative, expected in hashes.items():
    if digest(stage / relative) != expected:
        raise SystemExit('Stage byte mismatch: ' + relative)
if (stage / 'quod.x86_64').read_bytes()[:4] != b'\x7fELF':
    raise SystemExit('Exported engine is not ELF')

os.rename(installed, backup)
try:
    os.rename(stage, installed)
except BaseException:
    os.rename(backup, installed)
    raise

for relative, expected in hashes.items():
    if digest(installed / relative) != expected:
        raise SystemExit('Installed byte mismatch: ' + relative)

result = {
    'switch_exit': 0,
    'installed': str(installed),
    'backup': str(backup),
    'verified_export_files': len(hashes),
    'engine_sha256': digest(installed / 'quod.x86_64'),
    'managed_assembly_sha256': digest(installed / 'data_Quod_linuxbsd_x86_64/Quod.dll'),
    'pack_sha256': digest(installed / 'quod.pck'),
    'preserved': ['steam', 'last-run.log'],
    'saved_identity_opened': False,
}
receipt.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result))
