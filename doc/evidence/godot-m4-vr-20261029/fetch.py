"""Pinned HTTPS downloads; failures/partial bytes are preserved, never replaced."""
import hashlib,json,sys,time,urllib.request
from environment import TASK
name,url=sys.argv[1:3];expected=sys.argv[3] if len(sys.argv)>3 else None
target=TASK/'downloads'/name
started=time.time()
with urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'Quod-M4-native-qualification'}),timeout=90) as response,target.open('xb') as out:
    headers=dict(response.headers);final_url=response.url;status=response.status
    while data:=response.read(1024*1024):out.write(data)
actual=hashlib.sha256(target.read_bytes()).hexdigest()
receipt={'url':url,'final_url':final_url,'status':status,'headers':headers,'sha256':actual,'expected_sha256':expected,'bytes':target.stat().st_size,'seconds':time.time()-started}
target.with_name(target.name+'.receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(receipt))
if expected and actual!=expected:raise RuntimeError('Downloaded bytes do not match pinned SHA256')
