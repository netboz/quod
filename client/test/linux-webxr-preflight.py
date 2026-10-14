#!/usr/bin/env python3
"""Test a Chromium browser's native WebXR using WebDriver; never emulates XR."""
import argparse
import functools
import http.server
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import threading
import time
import urllib.error
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--evidence', type=Path, required=True)
parser.add_argument('--browser', type=Path, help='Browser executable; defaults to official Chrome for Testing')
parser.add_argument('--driver', type=Path, help='Matching ChromeDriver executable')
parser.add_argument('--frames', type=int, default=120, help='Frames per immersive session')
args = parser.parse_args()
if args.frames < 1:
    parser.error('--frames must be positive')
root = Path(__file__).resolve().parents[2]
base = root / 'client/_build/webxr-linux/chrome-testing'
chrome = (args.browser or base / 'chrome-linux64/chrome').resolve()
driver_path = (args.driver or base / 'chromedriver-linux64/chromedriver').resolve()
for artifact in [chrome, driver_path]:
    if not artifact.is_file():
        parser.error(f'Missing build artifact: {artifact}')
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(Path(__file__).parent))
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
origin = f'http://127.0.0.1:{server.server_port}'
session_id = None
code = 1
with (args.evidence / 'chromedriver.log').open('x') as log:
    driver = subprocess.Popen([str(driver_path), '--port=0', '--enable-chrome-logs'],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    drain = None
    try:
        received = b''
        deadline = time.monotonic() + 15
        with selectors.DefaultSelector() as selector:
            selector.register(driver.stdout, selectors.EVENT_READ)
            match = None
            while not match:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise RuntimeError('ChromeDriver startup deadline exceeded')
                chunk = os.read(driver.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError('ChromeDriver exited before startup')
                received += chunk
                log.write(chunk.decode(errors='replace')); log.flush()
                match = re.search(rb'started successfully on port (\d+)', received)
        endpoint = f'http://127.0.0.1:{match[1].decode()}'

        def copy_output():
            for line in driver.stdout:
                log.write(line.decode(errors='replace')); log.flush()

        drain = threading.Thread(target=copy_output)
        drain.start()

        def request(method, path, body=None):
            data = json.dumps(body).encode() if body is not None else None
            req = urllib.request.Request(endpoint + path, data=data, method=method,
                                         headers={'Content-Type': 'application/json'})
            try:
                response = urllib.request.urlopen(req, timeout=100)
            except urllib.error.HTTPError as error:
                raise RuntimeError(error.read().decode()) from error
            value = json.load(response)['value']
            if isinstance(value, dict) and 'error' in value:
                raise RuntimeError(json.dumps(value))
            return value

        created = request('POST', '/session', {'capabilities': {'alwaysMatch': {
            'browserName': 'chrome', 'goog:loggingPrefs': {'browser': 'ALL'},
            'goog:chromeOptions': {'binary': str(chrome), 'args': [
                '--enable-features=OpenXR', '--ozone-platform=wayland', '--no-first-run',
                '--no-default-browser-check', '--enable-logging=stderr', '--vmodule=openxr*=1',
                '--window-size=900,700',
                '--user-data-dir=' + str(Path(os.environ['XDG_DATA_HOME']) / 'chrome-profile'),
            ]},
        }}})
        session_id = created['sessionId']
        prefix = '/session/' + session_id

        def command(path, body=None):
            return request('POST', prefix + path, body or {})

        def evaluate(script, asynchronous=False):
            return command('/execute/' + ('async' if asynchronous else 'sync'), {'script': script, 'args': []})

        print(json.dumps({'event': 'engine', 'capabilities': created['capabilities']}), flush=True)
        command('/timeouts', {'script': 90000, 'pageLoad': 30000})
        command('/goog/cdp/execute', {'cmd': 'Browser.grantPermissions',
                'params': {'origin': origin, 'permissions': ['vr']}})
        command('/url', {'url': origin + '/linux-webxr.fixture.html?frames=' + str(args.frames)})
        ready = evaluate('window.preflightReady.then(arguments[arguments.length - 1])', True)
        print(json.dumps(ready), flush=True)
        if not ready or not all(ready.get(k) for k in ['secureContext', 'webxr', 'immersiveVR']):
            raise RuntimeError('Native immersive VR is unavailable')
        for cycle in range(2):
            evaluate("window.preflightNext = new Promise(resolve => { const listener = e => { "
                     "if (['session-complete','failed'].includes(e.detail.event)) { "
                     "window.removeEventListener('preflight-report', listener); resolve(e.detail); } }; "
                     "window.addEventListener('preflight-report', listener); })")
            element = command('/element', {'using': 'css selector', 'value': '#enter'})
            identifier = element['element-6066-11e4-a52e-4f735466cecf']
            command('/element/' + identifier + '/click')
            result = evaluate('window.preflightNext.then(arguments[arguments.length - 1])', True)
            print(json.dumps(result | {'cycle': cycle + 1}), flush=True)
            if result['event'] != 'session-complete':
                raise RuntimeError('Native immersive session failed')
        code = 0
    except Exception as error:
        print(json.dumps({'event': 'harness-failed', 'reason': str(error)}), flush=True)
    finally:
        if session_id:
            try:
                browser_log = command('/log', {'type': 'browser'})
                (args.evidence / 'console.json').write_text(json.dumps(browser_log, indent=2) + '\n')
                request('DELETE', prefix)
            except Exception as error:
                print(json.dumps({'event': 'cleanup-failed', 'reason': str(error)}), flush=True)
                code = 1
        if driver.poll() is None:
            driver.terminate()
        driver.wait(timeout=15)
        if drain:
            drain.join()
        driver.stdout.close()
server.shutdown()
raise SystemExit(code)
