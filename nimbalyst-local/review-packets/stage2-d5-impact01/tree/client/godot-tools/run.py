#!/usr/bin/env python3
"""Build/run the clean Godot client with the M0-qualified pinned toolchain."""
import argparse
import hashlib
import json
import os
import shutil
from pathlib import Path
import subprocess
import urllib.request
import zipfile

repo = Path(__file__).resolve().parents[2]
cache = repo / 'client/_build/godot-clean'
project = repo / 'client/godot'
engine_name = 'Godot_v4.7.2-stable_mono_linux_x86_64'
engine = cache / engine_name / 'Godot_v4.7.2-stable_mono_linux.x86_64'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bootstrap', action='store_true')
parser.add_argument('--build', action='store_true')
parser.add_argument('--export', action='store_true')
parser.add_argument('--xr', action='store_true', help='Enable the installed OpenXR runtime using the Vulkan mobile renderer')
parser.add_argument('arguments', nargs=argparse.REMAINDER)
args = parser.parse_args()
artifacts = json.loads((repo / 'doc/evidence/godot-m0-20261027/inputs/godot-artifacts.json').read_text())

if args.bootstrap:
    cache.mkdir(parents=True, exist_ok=True)
    for artifact in artifacts:
        archive_path = cache / artifact['name']
        if not archive_path.exists():
            with urllib.request.urlopen(artifact['url'], timeout=60) as source, archive_path.open('xb') as out:
                while block := source.read(1024 * 1024):
                    out.write(block)
        with archive_path.open('rb') as source:
            if hashlib.file_digest(source, 'sha256').hexdigest() != artifact['sha256']:
                raise SystemExit('Pinned Godot artifact hash mismatch: ' + artifact['name'])
        with zipfile.ZipFile(archive_path) as archive:
            for member in archive.infolist():
                if artifact['name'].endswith('.tpz') and not (member.filename.startswith('templates/linux_') or member.filename == 'templates/version.txt'):
                    continue
                destination = (cache / member.filename).resolve()
                if not destination.is_relative_to(cache.resolve()):
                    raise SystemExit('Invalid archive path')
                archive.extract(member, cache)
                mode = member.external_attr >> 16
                if mode:
                    destination.chmod(mode & 0o777)

env = dict(os.environ, NUGET_PACKAGES=str(cache / 'nuget'), XDG_DATA_HOME=str(cache / 'data'), XDG_CONFIG_HOME=str(cache / 'config'))
packages = cache / engine_name / 'GodotSharp/Tools/nupkgs'
if not engine.exists():
    raise SystemExit('Run with --bootstrap to install the pinned engine and templates.')
def run_engine(command):
    # Godot can exit zero after a failed managed publish. Preserve its output
    # and treat an engine error diagnostic as a failed launcher operation.
    child = subprocess.Popen(command, cwd=repo, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    diagnostic = False
    for line in child.stdout:
        print(line, end='', flush=True)
        diagnostic |= 'ERROR:' in line
    result = child.wait()
    if result or diagnostic:
        raise SystemExit(result or 1)
if args.build or args.export:
    subprocess.run(['dotnet', 'restore', str(project / 'Quod.csproj'), '--locked-mode', '--source', str(packages), '--source', 'https://api.nuget.org/v3/index.json'], cwd=project, env=env, check=True)
    subprocess.run(['dotnet', 'build', str(project / 'Quod.csproj'), '--no-restore'], cwd=project, env=env, check=True)
if args.export:
    (project / 'dist').mkdir(exist_ok=True)
    run_engine([str(engine), '--headless', '--path', str(project), '--export-release', 'Linux', str(project / 'dist/quod.x86_64')])
    for notice in sorted((project/'assets').glob('*LICENSE*')):
        shutil.copy2(notice,project/'dist'/notice.name)
elif args.arguments:
    arguments = args.arguments[1:] if args.arguments[0] == '--' else args.arguments
    xr_arguments = ['--xr-mode','on','--rendering-method','mobile','--rendering-driver','vulkan'] if args.xr else []
    run_engine([str(engine), '--path', str(project), *xr_arguments,*arguments])
