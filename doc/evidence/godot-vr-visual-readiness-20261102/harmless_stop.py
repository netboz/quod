"""A finite byte-transport check only; no application, fixture or domain owner."""
import json
import sys

line = sys.stdin.buffer.readline()
assert line == bytes.fromhex('73746f700a'), repr(line)
print('HARMLESS_STOP_PASS '+json.dumps({'stdin_hex':line.hex(),
    'stdin_is_tty':sys.stdin.isatty(),'application_fixture_runtime':False}),flush=True)
