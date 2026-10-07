from pathlib import Path
import json
import subprocess
import sys

repo = Path('/home/yan/src/quod')
evidence = Path('/tmp/quod-release-253-20261007')
attempt = evidence / 'attempt-03-after-interruption'
attempt.mkdir()

assert subprocess.check_output(['git', 'status', '--porcelain'], cwd=repo) == b''
head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip()
assert head == '3a97d47155419a24f038c7425bea2c24ddf1491a'
(attempt / 'reason.txt').write_text(
    'Attempt 01 was sandboxed and Ranch could not bind 127.0.0.1:0: '
    'listen_error eperm. Attempt 02 was interrupted with no exit receipt. Attempt 03 runs the same gates with loopback access.\n')

gates = [
    ('eunit', ['rebar3', 'as', 'test', 'eunit']),
    ('ct', ['rebar3', 'as', 'test', 'ct']),
    ('xref', ['rebar3', 'xref']),
    ('dialyzer', ['rebar3', 'dialyzer']),
]
for name, command in gates:
    with (attempt / f'{name}.log').open('x') as output:
        completed = subprocess.run(command, cwd=repo, stdout=output,
                                   stderr=subprocess.STDOUT)
    (attempt / f'{name}.exit.json').write_text(json.dumps({
        'exit': completed.returncode, 'command': command,
    }, indent=2) + '\n')
    tail = (attempt / f'{name}.log').read_text(errors='replace').splitlines()[-25:]
    print(f'--- {name} exit {completed.returncode} ---', flush=True)
    print('\n'.join(tail), flush=True)
    if completed.returncode:
        sys.exit(completed.returncode)
