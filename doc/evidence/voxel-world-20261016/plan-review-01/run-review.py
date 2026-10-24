import datetime
import hashlib
import json
import pathlib
import subprocess

directory = pathlib.Path(__file__).resolve().parent
manifest = json.loads((directory / 'source-manifest.json').read_text())


def mismatches(frozen):
    changed = []
    for row in manifest['files']:
        path = directory / 'tree' / row['file'] if frozen else pathlib.Path(row['source'])
        if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != row['sha256']:
            changed.append(row['file'])
    return changed


if mismatches(True) or mismatches(False):
    raise SystemExit('review inputs changed before invocation')

arguments = [
    '/home/yan/.local/bin/claude', '--print', '--model', 'fable',
    '--no-session-persistence', '--permission-mode', 'dontAsk',
    '--tools', 'Read,Grep,Glob', '--allowedTools', 'Read,Grep,Glob',
    '--disable-slash-commands', '--strict-mcp-config',
    '--mcp-config', '{"mcpServers":{}}',
    '--settings', '{"disableAllHooks":true}', '--output-format', 'json',
]
started = datetime.datetime.now(datetime.timezone.utc).isoformat()
(directory / 'invocation.json').write_text(json.dumps({
    'started': started, 'args': arguments, 'cwd': str(directory),
    'scope': 'User-requested voxel-world ontology plan review, including flying-lobby context only',
}, indent=2) + '\n')
with (directory / 'stdout.json').open('wb') as output, (directory / 'stderr.log').open('wb') as error:
    child = subprocess.run(arguments, cwd=directory,
                           input=(directory / 'review-request.md').read_bytes(),
                           stdout=output, stderr=error)
data = {}
try:
    data = json.loads((directory / 'stdout.json').read_text())
except (ValueError, UnicodeDecodeError):
    pass
if not isinstance(data, dict):
    data = {}
result = data.get('result')
if isinstance(result, str):
    (directory / 'fable-review.md').write_text(result + '\n')
models = list(data.get('modelUsage', {}))
frozen_changed = mismatches(True)
source_changed = mismatches(False)
valid = (child.returncode == 0 and data.get('is_error') is False
         and isinstance(result, str) and bool(result.strip())
         and any('fable' in model.lower() for model in models)
         and not frozen_changed and not source_changed)
receipt = {
    'started': started,
    'finished': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'child_exit': child.returncode, 'is_error': data.get('is_error'),
    'models': models, 'frozen_count': len(manifest['files']),
    'changed_frozen_inputs': frozen_changed, 'changed_source_inputs': source_changed,
    'review_valid': valid,
}
(directory / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt))
raise SystemExit(child.returncode if child.returncode else (0 if valid else 2))
