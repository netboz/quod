"""Verify retained committed prefixes, anchored identities and stable TLS origin."""
from pathlib import Path
import hashlib,json,socket,ssl,urllib.parse,urllib.request
b=Path(__file__).resolve().parent
assert json.loads((b/'release/PASSED.json').read_text())['passed']
before=json.loads((b/'history-before.json').read_text());origin=before['origin']
ctx=ssl._create_unverified_context()
def get(path):
 with urllib.request.urlopen(origin+path,context=ctx,timeout=40) as r:return json.load(r)
def save(name,value):
 with (b/name).open('x') as f:json.dump(value,f,indent=2);f.write('\n')
summary=get('/explorer/api/summary');save('history-summary-after.json',summary)
checks=[]
for item in before['blocks']:
 ns=item['namespace'];height=item['height'];name=item['file']
 assert hashlib.sha256((b/name).read_bytes()).hexdigest()==item['sha256']
 row=next(x for x in summary['namespaces'] if x['ns']==ns)
 assert row['genesis']==item['anchor'] and row['applied']>=height and not row['syncing']
 observed=get('/explorer/api/block/'+urllib.parse.quote(ns,safe='')+'/'+str(height))
 expected=json.loads((b/name).read_text());save(name.replace('-before.','-after.'),observed)
 assert observed==expected,(ns,height)
 checks.append({'namespace':ns,'height':height,'same_anchor':True,'unchanged':True,'current_applied':row['applied']})
with socket.create_connection(('gateway.internal',30519),timeout=20) as sock:
 with ctx.wrap_socket(sock,server_hostname='gateway.internal') as tls:cert=tls.getpeercert(binary_form=True)
fp=hashlib.sha256(cert).hexdigest()
assert fp==json.loads((b/'client-certificate-before.json').read_text())['sha256']
record={'blocks':checks,'certificate_sha256':fp,'same_certificate':True,'same_browser_origin':origin}
save('history-after.json',record);print(json.dumps(record))
