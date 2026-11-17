#!/usr/bin/env python3
"""Run one founding phase on the founder node: found.py <local|fleet> <phase>.

local  = the rehearsal container named in rehearsal/container (docker exec)
fleet  = the founder allocation named in founding/allocation (nomad alloc exec)

Each phase is one `quod eval` of quod_refound_operator (loaded by `load`). Its
command, exit, output and decoded result are kept beside it; a phase that has
already run refuses to run again. No retries.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
NOMAD = 'http://192.168.1.10:4646'
BEAM = HERE / 'quod_refound_operator.beam'
ORDER = ['load', 'root', 'node', 'agent', 'gui', 'gui-resume', 'controllers', 'names', 'space', 'user',
         'user-sign', 'user-submit', 'catalogue', 'gui-assets']


def place(target):
    directory = HERE / ('rehearsal' if target == 'local' else 'founding')
    name = (directory / ('container' if target == 'local' else 'allocation')).read_text().strip()
    return directory, name


def command(target, name, expression):
    if target == 'local':
        return ['docker', 'exec', name, '/opt/quod/bin/quod', 'eval', expression]
    return ['nomad', 'alloc', 'exec', '-i=false', '-t=false', '-address=' + NOMAD,
            '-task', 'quod', name, '/opt/quod/bin/quod', 'eval', expression]


def keep(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as handle:
        handle.write(text)


def evaluate(target, label, expression):
    directory, name = place(target)
    if (directory / (label + '.intent.json')).exists():
        raise SystemExit('Phase already run: ' + label)
    outer = 'binary_to_list(base64:encode(iolist_to_binary(json:encode(begin ' + expression + ' end)))).'
    argv = command(target, name, outer)
    keep(directory / (label + '.intent.json'), json.dumps({'target': target, 'on': name, 'expression': expression}, indent=2) + '\n')
    started = time.monotonic()
    result = subprocess.run(argv, capture_output=True, text=True)
    keep(directory / (label + '.exit.json'), json.dumps({'exit': result.returncode, 'seconds': round(time.monotonic() - started, 3)}) + '\n')
    keep(directory / (label + '.stdout'), result.stdout)
    keep(directory / (label + '.stderr'), result.stderr)
    if result.returncode:
        print('FAILED', label, 'exit', result.returncode, result.stdout[-2000:], result.stderr[-2000:], file=sys.stderr)
        raise SystemExit(result.returncode)
    try:
        wire = json.loads(result.stdout)
    except json.JSONDecodeError:
        # `quod eval` exits 0 for a failed expression and prints {error, ...}.
        print('FAILED', label, result.stdout[-3000:], file=sys.stderr)
        raise SystemExit(3)
    if isinstance(wire, list):
        wire = bytes(wire).decode('ascii')
    value = json.loads(base64.b64decode(wire, validate=True))
    keep(directory / (label + '.json'), json.dumps(value, indent=2, sort_keys=True) + '\n')
    print(label, json.dumps(value, sort_keys=True), flush=True)
    return value


def call(target, function, *args):
    return evaluate(target, function.replace('_', '-'), 'quod_refound_operator:' + function + '(' + ','.join(args) + ')')


def main():
    target, phase = sys.argv[1:]
    assert target in ('local', 'fleet') and phase in ORDER, (target, phase)
    directory, _ = place(target)
    if phase == 'load':
        data = BEAM.read_bytes()
        digest = hashlib.sha256(data).hexdigest().upper()
        payload = base64.b64encode(data).decode('ascii')
        evaluate(target, 'load', '{module,quod_refound_operator}=code:load_binary(quod_refound_operator,"' + digest +
                 '",base64:decode(<<"' + payload + '">>)),#{loaded=>true,beam_sha256=><<"' + digest + '">>}')
    elif phase == 'user-sign':
        operation = os.urandom(32).hex().upper()
        call(target, 'signed_user_registration', 'binary:decode_hex(<<"' + operation + '">>)')
    elif phase == 'user-submit':
        signed = json.loads((directory / 'signed-user-registration.json').read_text())
        call(target, 'submit_saved', '<<"' + signed['request'] + '">>', '<<"' + signed['signature'] + '">>')
    else:
        call(target, phase.replace('-', '_'))


if __name__ == '__main__':
    main()
