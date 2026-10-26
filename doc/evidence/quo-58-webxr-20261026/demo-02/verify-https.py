"""Read only the selected node's public TLS certificate, then verify HTTPS."""
from pathlib import Path
import base64, hashlib, json, ssl, subprocess, urllib.request

root = Path('/home/yan/src/quod')
out = root/'_build/quo-58-webxr-20261026/demo-02/deployment'
evidence = Path(__file__).resolve().parent
rows = json.loads((out/'scale-live.json').read_text())
matches = [r for r in rows if r['Name'].endswith('.quod-node[0]')]
assert len(matches) == 1
allocation = matches[0]['ID']
expression = '''
{ok,Dir}=application:get_env(quod,identity_dir),
{ok,Cert}=file:read_file(filename:join(Dir,"client_tls.crt")),
binary_to_list(base64:encode(iolist_to_binary(json:encode(#{
 root_anchor=>binary:encode_hex(quod_simplex:genesis_hash(<<"quod:root">>)),
 public_certificate=>base64:encode(Cert)})))).'''
command = ['nomad','alloc','exec','-i=false','-t=false',
           '-address=http://192.168.1.10:4646','-task','quod',allocation,
           '/opt/quod/bin/quod','eval',expression]
result = subprocess.run(command,capture_output=True,text=True)
with (out/'public-certificate-read.json').open('x') as f:
    json.dump({'allocation':allocation,'exit':result.returncode,
               'stdout':result.stdout,'stderr':result.stderr},f,indent=2)
assert result.returncode == 0
wire = json.loads(result.stdout)
if isinstance(wire,list): wire=bytes(wire).decode('ascii')
value = json.loads(base64.b64decode(wire,validate=True))
assert value['root_anchor'] == json.loads((out/'root-info.json').read_text())['root_anchor']
der = base64.b64decode(value['public_certificate'],validate=True)
pem = out/'client-public-certificate.pem'
with pem.open('x') as f: f.write(ssl.DER_cert_to_PEM_cert(der))
context=ssl.create_default_context(cafile=str(pem))
assert context.check_hostname and context.verify_mode == ssl.CERT_REQUIRED
url='https://192.168.1.10:30519/'
with urllib.request.urlopen(url,context=context,timeout=30) as response:
    peer=response.fp.raw._sock.getpeercert(binary_form=True)
    assert peer == der
    body=response.read()
    actual_headers=dict(response.headers)
    record={'url':url,'allocation':allocation,'root_anchor':value['root_anchor'],
            'status':response.status,'content_type':response.headers.get('Content-Type'),
            'certificate_sha256':hashlib.sha256(der).hexdigest(),
            'body_sha256':hashlib.sha256(body).hexdigest(),'bytes':len(body),
            'normal_hostname_verification':True,'exact_public_certificate_match':True}
assert record['status']==200 and b'<html' in body.lower()
expected_headers={
    'Content-Security-Policy': "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; font-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
    'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer',
    'Permissions-Policy': 'geolocation=(), microphone=(), camera=(), payment=()',
}
def check_headers(headers):
    lower={k.lower():v for k,v in headers.items()}
    assert all(lower.get(k.lower())==v for k,v in expected_headers.items()), lower
check_headers(actual_headers)
bundle=json.loads((evidence/'release-gates-01/bundle-manifest.json').read_text())
assert hashlib.sha256(body).hexdigest()==bundle['priv/explorer/world.html']
served=[]
for name,digest in sorted(bundle.items()):
    if not name.startswith('priv/explorer/assets/'): continue
    path=name.removeprefix('priv/explorer/')
    with urllib.request.urlopen(url+path,context=context,timeout=30) as response:
        content=response.read();check_headers(response.headers)
        actual=hashlib.sha256(content).hexdigest()
        assert response.status==200 and actual==digest,path
        served.append({'path':path,'sha256':actual,'bytes':len(content)})
with (evidence/'served-bundle.json').open('x') as f:
    json.dump({'world_html_matches':True,'security_headers':expected_headers,'assets':served},f,indent=2)
record.update(security_headers_match=True,world_html_matches=True,verified_assets=len(served))
with (evidence/'https-verified.json').open('x') as f:json.dump(record,f,indent=2)
print(json.dumps(record),flush=True)
