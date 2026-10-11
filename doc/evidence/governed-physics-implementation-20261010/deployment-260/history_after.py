"""Verify retained public committed blocks and the TLS gateway identity."""
from pathlib import Path
import hashlib,json,socket,ssl,urllib.parse,urllib.request
b=Path(__file__).resolve().parent
assert json.loads((b/'activate-route/PASSED.json').read_text())['passed']
base=json.loads((b.parents[1]/'quod27-personal-259-01/baseline.json').read_text())
ctx=ssl._create_unverified_context()
checks=[]
for label,height in [('human',350),('world',176)]:
 ns=base['dependencies'][0 if label=='human' else 1]['ns']
 url='https://192.168.1.10:30519/explorer/api/block/'+urllib.parse.quote(ns,safe='')+'/'+str(height)
 with urllib.request.urlopen(url,context=ctx,timeout=40) as response:observed=json.load(response)
 expected=json.loads((b/(label+'-tip-before.json')).read_text())
 with (b/(label+'-tip-after.json')).open('x') as out:json.dump(observed,out,indent=2);out.write('\n')
 assert observed==expected,label
 digest=hashlib.sha256(json.dumps(observed,sort_keys=True,separators=(',',':')).encode()).hexdigest()
 checks.append({'namespace':ns,'height':height,'unchanged':True,'canonical_sha256':digest})
with socket.create_connection(('192.168.1.10',30519),timeout=20) as sock:
 with ctx.wrap_socket(sock,server_hostname='192.168.1.10') as tls:cert=tls.getpeercert(binary_form=True)
fingerprint=hashlib.sha256(cert).hexdigest()
expected='b06f4c167933cf35b135e9b8d8c26b47084bad77a08bd6f42e85f7a0803cf1c4'
record={'blocks':checks,'certificate_sha256':fingerprint,'same_certificate':fingerprint==expected,'same_browser_origin':'https://192.168.1.10:30519'}
with (b/'history-after.json').open('x') as out:json.dump(record,out,indent=2);out.write('\n')
assert fingerprint==expected,'Investigate certificate change before browser acceptance'
print(json.dumps(record,indent=2))
