#!/usr/bin/env python3
"""Drive the actual export through a TLS reply-loss proxy to a real Quod fixture."""
import argparse
import base64
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import queue
import select
import socket
import shutil
import ssl
import subprocess
import threading
import time
from desktop_input import deliver
from shutdown_observation import ShutdownObservation, allow_owned_trace

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--export', type=Path, required=True)
p.add_argument('--backend-port', type=int, required=True)
p.add_argument('--backend-ca', type=Path, required=True)
p.add_argument('--control-port', type=int, required=True)
p.add_argument('--network', required=True)
p.add_argument('--evidence', type=Path, required=True)
p.add_argument('--private', type=Path, required=True)
p.add_argument('--desktop', action='store_true')
p.add_argument('--controllers', action='store_true')
p.add_argument('--journey', choices=['gui', 'spaces', 'navigation'], default='gui')
a = p.parse_args()
a.evidence = a.evidence.resolve()
a.evidence.mkdir(parents=True, exist_ok=False)
a.private.mkdir(mode=0o700, parents=True, exist_ok=False)
ca = a.private / 'proxy-ca.pem'
key = a.private / 'proxy-key.pem'
cert_command = ['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(key), '-out', str(ca), '-days', '1', '-subj', '/CN=127.0.0.1', '-addext', 'subjectAltName=IP:127.0.0.1', '-addext', 'basicConstraints=critical,CA:TRUE']
with (a.evidence / 'certificate.log').open('wb') as log:
    certificate = subprocess.run(cert_command, stdout=log, stderr=subprocess.STDOUT)
if certificate.returncode:
    raise SystemExit(certificate.returncode)
key.chmod(0o600)
trust = ssl.create_default_context(cafile=str(a.backend_ca))
records = []
record_lock = threading.Lock()
drops = {'signup': 0, 'setup': 0, 'instruction': 0}
faults = {'question_reply_lost': 0, 'question_unknown_error': 0}
question_error_armed = False
instruction_drop_armed = None
instruction_drop_operations = []
injections = {'duplicate_projection': 0, 'late_after_refresh': 0, 'prior_socket_projection': 0}
native_focus = []
first_projections = {}

class Proxy(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args):
        pass
    def do_GET(self):
        if self.path == '/qualification/traffic':
            with record_lock:
                value = {'cursor_opens': sum(r['route'] == '/api/goals/cursors' for r in records),
                         'questions': sum(r.get('flow') == 'question' for r in records),
                         'writes': sum(r.get('request_sha256') is not None for r in records),
                         'instructions': sum(r.get('flow') == 'instruction' for r in records),
                         'receiver_selections': sum(r.get('flow') == 'receiver' for r in records)}
            self.json_reply(200, value)
        elif self.headers.get('Upgrade', '').lower() == 'websocket':
            self.tunnel()
        else:
            self.forward()
    def do_POST(self):
        global question_error_armed, instruction_drop_armed
        if self.path == '/qualification/arm-instruction-drop':
            body=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))))
            if body.get('operation') not in ('enter','leave') or instruction_drop_armed is not None:
                self.json_reply(400,{'error':'invalid fault selection'}); return
            instruction_drop_armed=body['operation']; self.json_reply(200,{'armed':instruction_drop_armed}); return
        if self.path == '/qualification/arm-question-error':
            self.rfile.read(int(self.headers.get('Content-Length', '0')))
            with record_lock: question_error_armed = True
            self.json_reply(200, {'armed': True}); return
        self.forward()
    def do_DELETE(self):
        self.forward()
    def forward(self):
        global question_error_armed, instruction_drop_armed
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        encoded = json.loads(body).get('request') if body else None
        request = base64.urlsafe_b64decode(encoded + '=' * ((-len(encoded)) % 4)) if encoded else b''
        if self.path == '/api/goals/execute' and b'gui_submit(' in request:
            with record_lock:
                uncertain = question_error_armed
                if uncertain:
                    question_error_armed = False; faults['question_unknown_error'] += 1
                    records.append({'method': self.command, 'route': self.path, 'status': 503, 'flow': 'question',
                        'request_sha256': hashlib.sha256(request).hexdigest(), 'reply_lost': False, 'test_fault_before_forward': True})
            if uncertain:
                self.json_reply(503, {'error': 'outcome_index_corrupt'}); return
        connection = http.client.HTTPSConnection('127.0.0.1', a.backend_port, context=trust, timeout=300)
        headers = {k: v for k, v in self.headers.items() if k.lower() not in ('host', 'connection')}
        try:
            connection.request(self.command, self.path, body, headers)
            response = connection.getresponse()
            content = response.read()
            flow = None
            digest = None
            if self.path in ('/api/goals/execute', '/api/agents/instructions'):
                encoded = json.loads(body)['request']
                request = base64.urlsafe_b64decode(encoded + '=' * ((-len(encoded)) % 4))
                digest = hashlib.sha256(request).hexdigest()
                if self.path == '/api/agents/instructions':
                    flow = 'instruction'
                elif b'setup_account(' in request:
                    flow = 'setup'
                elif b'signup(' in request:
                    flow = 'signup'
                elif b'gui_submit(' in request:
                    flow = 'question'
                elif b'gui_select_receiver(' in request:
                    flow = 'receiver'
            lose = False
            with record_lock:
                if flow in drops and response.status < 300 and drops[flow] < (2 if flow == 'instruction' and a.journey == 'gui' else 1):
                    drops[flow] += 1
                    lose = True
                if flow=='instruction' and response.status<300 and instruction_drop_armed is not None:
                    drops[flow]+=1; lose=True; instruction_drop_operations.append(instruction_drop_armed); instruction_drop_armed=None
                if flow == 'question' and response.status < 300 and faults['question_reply_lost'] == 0:
                    faults['question_reply_lost'] += 1; lose = True
                asset=self.path.startswith('/assets/')
                reply = {} if asset else json.loads(content)
                records.append({'method': self.command, 'route': self.path, 'status': response.status, 'flow': flow, 'request_sha256': digest, 'reply_lost': lose,
                    'result': reply.get('result'), 'outcome_status': reply.get('status'), 'aggregate': reply.get('aggregate'),
                    **({'asset_bytes':len(content),'asset_sha256':hashlib.sha256(content).hexdigest()} if asset else {})})
            if lose:
                with socket.create_connection(('127.0.0.1', a.control_port), timeout=10) as owner:
                    owner.sendall(json.dumps({'request': encoded}).encode() + b'\n')
                    if json.loads(owner.makefile('rb').readline()) != {'terminal': True}:
                        raise RuntimeError('Original operation did not reach its owner completion fence')
                # The real server has produced its original response. Lose only
                # that response; the proxy never retries or changes signed bytes.
                self.close_connection = True
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
                return
            self.send_response(response.status)
            self.send_header('Content-Type', response.getheader('Content-Type', 'application/json'))
            self.send_header('Content-Length', str(len(content)))
            self.end_headers()
            self.wfile.write(content)
        finally:
            connection.close()
    def json_reply(self, status, value):
        content = json.dumps(value).encode()
        self.send_response(status); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(content))); self.end_headers(); self.wfile.write(content)
    def tunnel(self):
        upstream = trust.wrap_socket(socket.create_connection(('127.0.0.1', a.backend_port)), server_hostname='127.0.0.1')
        try:
            headers = ''.join(f'{k}: {v}\r\n' for k, v in self.headers.items() if k.lower() != 'host')
            upstream.sendall((f'GET {self.path} HTTP/1.1\r\nHost: 127.0.0.1:{a.backend_port}\r\n' + headers + '\r\n').encode())
            handshake = b''
            while b'\r\n\r\n' not in handshake:
                block = upstream.recv(16384)
                if not block:
                    raise RuntimeError('Incomplete upstream WebSocket handshake')
                handshake += block
            header, payload = handshake.split(b'\r\n\r\n', 1)
            self.connection.sendall(header + b'\r\n\r\n')
            self.close_connection = True
            buffered = bytearray(payload)
            previous = None
            def frames(block):
                nonlocal previous
                buffered.extend(block)
                while len(buffered) >= 2:
                    length, offset = buffered[1] & 127, 2
                    if length in (126, 127):
                        width = 2 if length == 126 else 8
                        if len(buffered) < offset + width: return
                        length = int.from_bytes(buffered[offset:offset+width], 'big'); offset += width
                    if buffered[1] & 128: raise RuntimeError('Unexpected masked server frame')
                    if len(buffered) < offset + length: return
                    frame = bytes(buffered[:offset+length]); del buffered[:offset+length]
                    message = json.loads(frame[offset:]) if frame[0] == 129 else {}
                    if message.get('type') == 'projection':
                        kind = message.get('kind', 'world')
                        with record_lock:
                            old = first_projections.setdefault(kind, frame)
                            if previous is None and old != frame:
                                self.connection.sendall(old); injections['prior_socket_projection'] += 1
                            self.connection.sendall(frame); self.connection.sendall(frame)
                            injections['duplicate_projection'] += 1
                        previous = frame
                    else:
                        self.connection.sendall(frame)
                        if message.get('type') == 'refresh' and previous is not None:
                            self.connection.sendall(previous)
                            with record_lock: injections['late_after_refresh'] += 1
            frames(b'')
            while True:
                ready, _, _ = select.select([self.connection, upstream], [], [])
                for source in ready:
                    block = source.recv(65536)
                    if not block:
                        return
                    if source is self.connection: upstream.sendall(block)
                    else: frames(block)
        except (ConnectionError, OSError, ssl.SSLError):
            return
        finally:
            upstream.close()

server = ThreadingHTTPServer(('127.0.0.1', 0), Proxy)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(str(ca), str(key))
server.socket = context.wrap_socket(server.socket, server_side=True)
threading.Thread(target=server.serve_forever, daemon=True).start()
origin = f'https://127.0.0.1:{server.server_port}'
results = []
try:
    phases={'gui':('fresh','reset','final'),'spaces':('m2-fresh','m2-final'),
            'navigation':('m3-fresh','m3-created','m3-entered','m3-left','m3-final','m3-negative-recovered')}[a.journey]
    if a.controllers:
        if a.journey!='gui':raise ValueError('Controller integration extends the existing GUI journey')
        phases=('fresh','reset','m4-live','final')
    for phase in phases:
        env = dict(os.environ, M1B_PHASE=phase, M1B_NETWORK=a.network,
                   M1B_ORIGINAL=str(a.private / 'original.json'), M1B_RESULT=str(a.evidence / 'export-result.json'),
                   M1B_OLD_OFFER=str(a.private / 'old-offer.json'), M1B_CONTROL_PORT=str(a.control_port),
                   M1B_CORPUS=str((Path.cwd() / 'client/test/fixtures/native-contract/contracts.json').resolve()),
                   M1B_ACCOUNT_BACKUP=str(a.private / 'account-backup.json'),
                   XDG_DATA_HOME=str(a.private / 'data'), XDG_CONFIG_HOME=str(a.private / 'config'), DOTNET_ROOT=str(a.private / 'no-installed-runtime'))
        if a.controllers:env['M4_REPAIR']='1'
        if a.journey == 'spaces' and a.desktop:
            env['M2_SCREENSHOT'] = str((a.evidence / 'space-ui.png').resolve())
        if a.journey=='navigation':
            env.update(M3_ROUTE=str(a.private/'route.json'),M3_SCENE_CAPTURE=str(a.evidence/'recursive-scene.png'),M1B_RESULT=str(a.evidence/(phase+'-result.json')))
        display = ['--display-driver', 'wayland'] if a.desktop else ['--headless']
        command = [str(a.export.resolve())] + display + ['--', '--qualification', '--profile', str(a.private / 'identity'), '--node', origin, '--ca', str(ca)]
        start = time.monotonic()
        child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, text=True, preexec_fn=allow_owned_trace)
        output = queue.Queue()
        reader_errors=[]
        def read_output():
            try:
                for line in child.stdout:output.put(line)
            except Exception as error:reader_errors.append(type(error).__name__)
            finally:output.put(None)
        reader=threading.Thread(target=read_output);reader.start()
        observation=ShutdownObservation(child,a.private/(phase+"-shutdown-diagnostic"))
        killed = False
        text = ''
        with (a.evidence / f'{phase}.log').open('w') as log:
            while True:
                try:
                    line = output.get(timeout=60)
                except queue.Empty:
                    child.kill()
                    actual = child.wait(timeout=10)
                    observation.finish();reader.join(timeout=5)
                    results.append({'phase': phase, 'command': command, 'child_exit': actual, 'passed': False,
                                    'watchdog_progress_missing': True, 'elapsed_seconds': time.monotonic() - start})
                    raise RuntimeError('No qualification progress within the test watchdog')
                if line is None:
                    break
                log.write(line)
                log.flush()
                text += line
                observation.observe(line)
                print(phase + ': ' + line.rstrip(), flush=True)
                try: deliver(line, child.pid, a.desktop, native_focus)
                except Exception:
                        child.kill(); child.wait();observation.finish();reader.join(timeout=5)
                        results.append({'phase': phase, 'command': command, 'child_exit': child.returncode,
                            'passed': False, 'native_activation_failed': True})
                        raise
                if line.startswith('M1B_KILL_READY '):
                    child.kill()
                    killed = True
        exit_code = child.wait(timeout=10)
        shutdown_observation=observation.finish();reader.join(timeout=5)
        expected = -9 if phase in ('fresh', 'reset', 'm2-fresh','m3-fresh','m3-created','m3-entered') else 0
        result = {'phase': phase, 'command': command, 'child_exit': exit_code, 'expected_exit': expected,
                  'external_sigkill_at_observed_seam': killed, 'elapsed_seconds': time.monotonic() - start,
                  'godot_error_diagnostics': 'ERROR:' in text, 'shutdown_observation': shutdown_observation, 'output_eof':not reader.is_alive(), 'reader_errors':reader_errors, 'passed': exit_code == expected and 'ERROR:' not in text and not reader.is_alive() and not reader_errors}
        results.append(result)
        if not result['passed']:
            raise RuntimeError('Export qualification phase failed: ' + phase)
        if killed:
            shutil.copytree(a.private / 'identity', a.private / (phase + '-store'))
    mutations = [r for r in records if r['request_sha256']]
    ids = [r['request_sha256'] for r in mutations]
    if len(ids) != len(set(ids)):
        raise RuntimeError('A signed mutation was submitted twice')
    if drops != {'signup': 1, 'setup': 1, 'instruction': {'gui':2,'spaces':1,'navigation':3}[a.journey]}:
        raise RuntimeError('Required response-loss cases were not exercised')
    if a.journey=='navigation' and instruction_drop_operations!=['enter','leave']:
        raise RuntimeError('Required actual Enter and Leave reply-loss seams were not observed')
    if a.journey == 'gui' and faults != {'question_reply_lost': 1, 'question_unknown_error': 1}:
        raise RuntimeError('Required deferred-question uncertainty cases were not exercised')
    if not all(injections.values()): raise RuntimeError('Required stale and duplicate projection cases were not exercised')
finally:
    server.shutdown()
    (a.evidence / 'transport.json').write_text(json.dumps({'certificate_command': cert_command, 'certificate_child_exit': certificate.returncode,
        'origin': origin, 'expected_hostname': '127.0.0.1', 'ca_sha256': hashlib.sha256(ca.read_bytes()).hexdigest(),
        'backend_ca_sha256': hashlib.sha256(a.backend_ca.read_bytes()).hexdigest(), 'certificate_validation': True,
        'drops': drops, 'question_faults': faults, 'projection_injections': injections, 'requests': records}, indent=2) + '\n')
    (a.evidence / 'phases.json').write_text(json.dumps(results, indent=2) + '\n')
    (a.evidence / 'native-focus.json').write_text(json.dumps(native_focus, indent=2) + '\n')
