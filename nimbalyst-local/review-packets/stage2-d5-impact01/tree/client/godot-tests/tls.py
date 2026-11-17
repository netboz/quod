#!/usr/bin/env python3
"""TLS-only endpoints; the exported production transport makes every check."""
import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import ssl
import subprocess
import threading

p = argparse.ArgumentParser()
p.add_argument('--export', type=Path, required=True)
p.add_argument('--evidence', type=Path, required=True)
p.add_argument('--private', type=Path, required=True)
a = p.parse_args()
a.evidence.mkdir(parents=True, exist_ok=False)
a.private.mkdir(mode=0o700, parents=True, exist_ok=False)
key, cert, expired = [a.private / name for name in ('key.pem', 'ca.pem', 'expired.pem')]
commands = [
    ['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(key), '-out', str(cert), '-days', '1', '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost'],
    ['openssl', 'req', '-x509', '-key', str(key), '-out', str(expired), '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost', '-not_before', '20200101000000Z', '-not_after', '20200102000000Z']]
records = []
for i, command in enumerate(commands):
    with (a.evidence / ('certificate-' + str(i) + '.log')).open('wb') as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    records.append({'command': command, 'child_exit': result.returncode})
    if result.returncode: raise SystemExit(result.returncode)
key.chmod(0o600)
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        if self.headers.get('Upgrade', '').lower() == 'websocket':
            accept = base64.b64encode(hashlib.sha1((self.headers['Sec-WebSocket-Key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            self.send_response(101); self.send_header('Upgrade', 'websocket'); self.send_header('Connection', 'Upgrade'); self.send_header('Sec-WebSocket-Accept', accept); self.end_headers()
        else:
            body = b'{"tls":"ok"}'
            self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
servers = []
try:
    for certificate in (cert, expired):
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(certificate, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        threading.Thread(target=server.serve_forever, daemon=True).start(); servers.append(server)
    port, old_port = [s.server_port for s in servers]
    for label, url, ca, expect in [('trusted', f'https://localhost:{port}', cert, 'accept'), ('untrusted', f'https://localhost:{port}', '', 'reject'), ('wrong-host', f'https://127.0.0.1:{port}', cert, 'reject'), ('expired', f'https://localhost:{old_port}', cert, 'reject')]:
        env = dict(os.environ, M1B_PHASE='tls', M1B_TLS_CASE=label, M1B_TLS_URL=url, M1B_TLS_CA=str(ca), M1B_TLS_EXPECT=expect,
                   DOTNET_ROOT=str(a.private / 'no-runtime'), XDG_DATA_HOME=str(a.private / 'data'), XDG_CONFIG_HOME=str(a.private / 'config'))
        command = [str(a.export), '--headless', '--', '--qualification', '--profile', str(a.private / label)]
        result = subprocess.run(command, env=env, capture_output=True, timeout=30)
        text = (result.stdout + result.stderr).decode(errors='replace')
        (a.evidence / (label + '.log')).write_text(text)
        records.append({'case': label, 'command': command, 'child_exit': result.returncode, 'expected': expect})
        if result.returncode or 'M1B_TLS_PASS' not in text or 'ERROR:' in text:
            raise RuntimeError(label + ' failed; retained full log')
finally:
    for server in servers: server.shutdown(); server.server_close()
    (a.evidence / 'result.json').write_text(json.dumps(records, indent=2) + '\n')
