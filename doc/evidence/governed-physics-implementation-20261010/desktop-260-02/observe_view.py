from pathlib import Path
import base64,json,sys
import browser as b
p=Path(__file__).resolve().parent;label=sys.argv[1]
with (p/(label+'.intent.json')).open('x') as out:json.dump({'refresh':'--refresh' in sys.argv},out)
b.command('/window',{'handle':'A7F6E2EB6874B3F706E82AC4282A742C'})
b.command('/goog/cdp/execute',{'cmd':'Page.bringToFront','params':{}})
b.command('/log',{'type':'performance'})
if '--refresh' in sys.argv:
 b.command('/refresh')
 ready=b.wait_js('document.querySelector(".world-panel [role=status]")?.textContent === "Physical space ready."')
else:ready=None
state=b.inspect();frames=[];requests=[]
for row in b.command('/log',{'type':'performance'}):
 m=json.loads(row['message'])['message'];v=m.get('params',{})
 if m['method']=='Network.webSocketFrameReceived':
  try:payload=json.loads(v['response']['payloadData'])
  except (ValueError,KeyError):continue
  if payload.get('type') in ['projection','simulation_frame','refresh','unavailable']:
   frames.append({'timestamp':v.get('timestamp'),'request_id':v.get('requestId'),'data':payload})
 if m['method']=='Network.requestWillBeSent':
  requests.append({'method':v['request']['method'],'url':v['request']['url'].split('?')[0]})
for suffix,value in [('dom',state),('frames',frames),('requests',requests)]:
 with (p/(label+'-'+suffix+'.json')).open('x') as out:json.dump(value,out,indent=2)
with (p/(label+'.png')).open('xb') as out:out.write(base64.b64decode(b.command('/screenshot',method='GET')))
print(json.dumps({'ready':ready,'status':state['text'],'frames':len(frames)}))
if '--refresh' in sys.argv:assert ready,'Normal view did not reach its existing ready state'
