import json,re,urllib.request
from pathlib import Path
p=Path('/home/yan/src/quod/doc/evidence/quo-58-webxr-20261026/view-correction-01/desktop-diagnosis-03')
s=json.loads((p/'owner.json').read_text())['webdriver_session']
port=re.search(r'started successfully on port (\d+)',(p/'chromedriver.log').read_text())[1]
base=f'http://127.0.0.1:{port}/session/{s}'
def call(path,data):
 r=urllib.request.Request(base+path,data=json.dumps(data).encode(),headers={'Content-Type':'application/json'})
 with urllib.request.urlopen(r,timeout=35) as f:return json.load(f)['value']
def cdp(cmd,params):return call('/goog/cdp/execute',{'cmd':cmd,'params':params})
cdp('Page.removeScriptToEvaluateOnNewDocument',{'identifier':'2'})
print(cdp('Page.addScriptToEvaluateOnNewDocument',{'source':(p/'observe-corrected.js').read_text()}),flush=True)
call('/refresh',{})
r=call('/execute/async',{'script':'const done=arguments[arguments.length-1];window.quodFirstView.then(done);','args':[]})
with (p/'02-authoritative-clearance.json').open('x') as f:json.dump(r,f,indent=2)
print(json.dumps(r),flush=True)
