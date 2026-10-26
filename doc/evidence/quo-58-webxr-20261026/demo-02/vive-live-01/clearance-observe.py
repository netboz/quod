import json,re,urllib.request
from pathlib import Path
base=Path('/home/yan/src/quod/doc/evidence/quo-58-webxr-20261026/demo-02/vive-live-01')
owner=json.loads((base/'runtime-owners.json').read_text())
port=re.search(r'started successfully on port (\d+)',(base/'chromedriver.log').read_text())[1]
url=f'http://127.0.0.1:{port}/session/'+owner['webdriver_session']+'/goog/cdp/execute'
def cdp(cmd,params):
    req=urllib.request.Request(url,data=json.dumps({'cmd':cmd,'params':params}).encode(),headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=35) as r:return json.load(r)['value']
try:
    prototype=cdp('Runtime.evaluate',{'expression':'WebSocket.prototype','objectGroup':'quod-clearance-observation'})['result']['objectId']
    sockets=cdp('Runtime.queryObjects',{'prototypeObjectId':prototype,'objectGroup':'quod-clearance-observation'})['objects']['objectId']
    result=cdp('Runtime.callFunctionOn',{'objectId':sockets,'awaitPromise':True,'returnByValue':True,'functionDeclaration':'''function(){return new Promise(resolve=>{
      const sockets=Array.from(this).filter(s=>s.readyState===WebSocket.OPEN), rows=[], removers=[];
      let finished=false;
      const finish=()=>{if(finished)return;finished=true;removers.forEach(f=>f());clearTimeout(deadline);resolve({openSockets:sockets.length,rows});};
      const deadline=setTimeout(finish,10000);
      for(const socket of sockets){const listener=e=>{try{const m=JSON.parse(e.data),f=m.frame??m;
        if(f.view_clearance!==undefined){rows.push({at:Date.now(),type:m.type,clearance:f.view_clearance,tick:f.tick,control:m.control??null});if(rows.length===6)finish();}
      }catch{}};socket.addEventListener('message',listener);removers.push(()=>socket.removeEventListener('message',listener));}
    });}'''})
    with (base/'12-live-clearance.json').open('x') as f:json.dump(result,f,indent=2)
    print(json.dumps(result))
finally:cdp('Runtime.releaseObjectGroup',{'objectGroup':'quod-clearance-observation'})
