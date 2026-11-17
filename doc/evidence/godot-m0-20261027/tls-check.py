#!/usr/bin/env python3
"""Exported managed client TLS with ordinary trust/name/validity checks, local only."""
import http.server
import json
import os
from pathlib import Path
import ssl
import subprocess
import tempfile
import threading

out=Path(__file__).resolve().parent/'logs'/os.environ.get('M0_TLS_DETAIL','tls-detail-02')
out.mkdir(exist_ok=False)
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200);self.end_headers();self.wfile.write(b'qualification')
    def log_message(self,*args):pass

results=[]
with tempfile.TemporaryDirectory(prefix='quod-m0-tls-') as d:
    d=Path(d);key=d/'key.pem';cert=d/'ca.pem';expired=d/'expired.pem'
    commands=[['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(key),'-out',str(cert),'-days','1','-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost'],
              ['openssl','req','-x509','-key',str(key),'-out',str(expired),'-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost','-not_before','20200101000000Z','-not_after','20200102000000Z']]
    for i,command in enumerate(commands):
        r=subprocess.run(command,capture_output=True);(out/f'certificate-{i}.log').write_bytes(r.stdout+r.stderr);assert r.returncode==0
    servers=[]
    try:
        for pem in [cert,expired]:
            server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
            context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(pem,key)
            server.socket=context.wrap_socket(server.socket,server_side=True)
            threading.Thread(target=server.serve_forever,daemon=True).start();servers.append(server)
        port=servers[0].server_port;old=servers[1].server_port
        for label,url,trust,expect in [('trusted',f'https://localhost:{port}',True,'accept'),('untrusted',f'https://localhost:{port}',False,'reject'),('wrong-host',f'https://127.0.0.1:{port}',True,'reject'),('expired',f'https://localhost:{old}',True,'reject')]:
            env=dict(os.environ,XDG_DATA_HOME='/tmp/quod-m0-godot-data',XDG_CONFIG_HOME='/tmp/quod-m0-godot-config',M0_MODE='tls',M0_CA=str(cert),M0_URL=url,M0_TRUST='yes' if trust else 'no',M0_TLS_EXPECT=expect)
            env.pop('LD_LIBRARY_PATH',None);env.pop('LD_PRELOAD',None)
            command=['/tmp/quod-godot-m0-export/m0.x86_64','--headless']
            r=subprocess.run(command,env=env,capture_output=True,timeout=25);text=(r.stdout+r.stderr).decode(errors='replace');(out/(label+'.log')).write_text(text)
            results.append(dict(label=label,command=command,child_exit=r.returncode,expected=expect))
            assert r.returncode==0 and 'M0_PROBE_PASS' in text and 'ERROR:' not in text,(label,text)
    finally:
        for server in servers:server.shutdown();server.server_close()
(out/'result.json').write_text(json.dumps(results,indent=2)+'\n');print(json.dumps(results,indent=2))
