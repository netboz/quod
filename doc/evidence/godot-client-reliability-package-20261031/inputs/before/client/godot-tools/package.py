#!/usr/bin/env python3
"""Package an explicitly qualified complete export; never compile or install it."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import stat
import tarfile


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def relative(name):
    path = PurePosixPath(name)
    if path.is_absolute() or not path.parts or '..' in path.parts or str(path) != name:
        raise ValueError('Invalid package member')
    return path


def package(manifest, expected, extras, output):
    if digest(manifest) != expected:
        raise ValueError('Export manifest identity mismatch')
    source = json.loads(manifest.read_text())
    if not source['passed'] or not source['tracefree_product_composition'] or source['diagnostic_overrides']:
        raise ValueError('Only a qualified trace-free product export can be packaged')
    dist = Path(source['export_executable']).parent
    files = source['export_outputs']
    if set(files) != {str(p.relative_to(dist)) for p in dist.rglob('*') if p.is_file()}:
        raise ValueError('Export path set differs from manifest')
    entries = {}
    for name, row in files.items():
        relative(name)
        path = dist / name
        if not stat.S_ISREG(path.lstat().st_mode) or path.stat().st_size != row['bytes']:
            raise ValueError('Export member type/size mismatch')
        entries[name] = (path, row['sha256'], stat.S_IMODE(path.stat().st_mode))
    spec = json.loads(extras.read_text())
    for name, row in spec.items():
        relative(name)
        if name in entries:
            raise ValueError('Extra member would replace an export')
        path = extras.parent / row['source']
        if not stat.S_ISREG(path.lstat().st_mode):
            raise ValueError('Extra member must be an ordinary file')
        entries[name] = (path, row['sha256'], row['mode'])
    index = {name: {'sha256': sha, 'bytes': path.stat().st_size, 'mode': mode}
             for name, (path, sha, mode) in sorted(entries.items())}
    metadata = (json.dumps({'export_manifest_sha256': expected, 'files': index}, sort_keys=True, indent=2) + '\n').encode()
    directories = {str(p) for name in entries for p in PurePosixPath(name).parents if str(p) != '.'}
    with output.open('xb') as sink, gzip.GzipFile(filename='', mode='wb', fileobj=sink, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode='w|', format=tarfile.PAX_FORMAT) as archive:
            for name in ['quod-linux-x86_64', *['quod-linux-x86_64/' + n for n in sorted(directories)]]:
                member = tarfile.TarInfo(name); member.type = tarfile.DIRTYPE; member.mode = 0o755
                archive.addfile(member)
            for name, (path, expected_sha, mode) in sorted(entries.items()):
                # Read once while composing the new archive. Bind the bytes we
                # actually package, rather than trusting a mutable dist filename.
                data = path.read_bytes()
                if hashlib.sha256(data).hexdigest() != expected_sha:
                    raise ValueError('Package input content mismatch: ' + name)
                member = tarfile.TarInfo('quod-linux-x86_64/' + name); member.size = len(data); member.mode = mode
                archive.addfile(member, io.BytesIO(data))
            member = tarfile.TarInfo('quod-linux-x86_64/package-manifest.json'); member.size = len(metadata); member.mode = 0o644
            archive.addfile(member, io.BytesIO(metadata))
    return {'archive_sha256': digest(output), 'archive_bytes': output.stat().st_size,
            'export_manifest_sha256': expected, 'export_files': len(files), 'package_files': len(entries) + 1,
            'files': index, 'reproducible_headers': True, 'compiled': False, 'installed': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--manifest-sha256', required=True)
    parser.add_argument('--extras', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--receipt', type=Path, required=True)
    args = parser.parse_args()
    result = package(args.manifest, args.manifest_sha256, args.extras, args.output)
    args.receipt.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'files'}))
