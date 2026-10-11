from pathlib import Path
import base64, json, sys
import browser as b

p=Path(__file__).resolve().parent
label,key,duration=sys.argv[1],sys.argv[2],int(sys.argv[3])
assert 0 < duration <= 10000
with (p/(label+'.intent.json')).open('x') as f:
 json.dump({'kind':'normal desktop keyboard input','key':key,'held_ms':duration},f)
b.command('/goog/cdp/execute',{'cmd':'Page.bringToFront','params':{}})
if not b.evaluate('return document.pointerLockElement===document.querySelector("canvas.world-canvas")'):
 x,y=b.evaluate('return [Math.round(innerWidth*0.8),Math.round(innerHeight*0.7)]')
 b.evaluate('window.quodPointerCompletion=new Promise(resolve=>{let timer;const finish=()=>{clearTimeout(timer);document.removeEventListener("pointerlockchange",finish);document.removeEventListener("pointerlockerror",finish);resolve(document.pointerLockElement===document.querySelector("canvas.world-canvas"))};document.addEventListener("pointerlockchange",finish);document.addEventListener("pointerlockerror",finish);timer=setTimeout(finish,5000)})')
 b.command('/actions',{'actions':[{'type':'pointer','id':'mouse','parameters':{'pointerType':'mouse'},'actions':[
  {'type':'pointerMove','origin':'viewport','x':x,'y':y},
  {'type':'pointerDown','button':0},{'type':'pointerUp','button':0}]}]})
 assert b.command('/execute/async',{'script':'const done=arguments[0];quodPointerCompletion.then(done)','args':[]})
assert b.evaluate('return document.pointerLockElement===document.querySelector("canvas.world-canvas")'),'pointer lock absent'
with (p/(label+'-before.png')).open('xb') as f:f.write(base64.b64decode(b.command('/screenshot',method='GET')))
b.evaluate('window.quodStepClock={count:0,start:performance.now(),active:true};const frame=()=>{if(quodStepClock.active){quodStepClock.count++;requestAnimationFrame(frame)}};requestAnimationFrame(frame)')
b.command('/actions',{'actions':[{'type':'key','id':'desktop','actions':[
 {'type':'keyDown','value':key},{'type':'pause','duration':duration},{'type':'keyUp','value':key}]}]})
cadence=b.evaluate('quodStepClock.active=false;return {...quodStepClock,elapsed:performance.now()-quodStepClock.start}')
state=b.inspect()
with (p/(label+'-dom.json')).open('x') as f:json.dump(state,f,indent=2)
with (p/(label+'.png')).open('xb') as f:f.write(base64.b64decode(b.command('/screenshot',method='GET')))
frames=[];requests=[];responses=[]
for row in b.command('/log',{'type':'performance'}):
 m=json.loads(row['message'])['message'];v=m.get('params',{})
 if m['method']=='Network.webSocketFrameReceived':
  try:payload=json.loads(v['response']['payloadData'])
  except (ValueError,KeyError):continue
  if payload.get('type') in ['projection','simulation_frame','refresh','unavailable']:
   frames.append({'timestamp':v.get('timestamp'),'request_id':v.get('requestId'),'data':payload})
 if m['method']=='Network.requestWillBeSent' and '/api/' in v['request']['url']:
  requests.append({'id':v['requestId'],'method':v['request']['method'],'url':v['request']['url'].split('?')[0]})
 if m['method']=='Network.responseReceived' and '/api/goals/control' in v['response']['url']:
  record={'id':v['requestId'],'status':v['response']['status']}
  try:
   raw=b.command('/goog/cdp/execute',{'cmd':'Network.getResponseBody','params':{'requestId':v['requestId']}})
   payload=json.loads(base64.b64decode(raw['body']) if raw.get('base64Encoded') else raw['body'])
   record.update({k:payload[k] for k in ['result','reasons','error'] if k in payload})
  except Exception as error:record['capture_error']=type(error).__name__
  responses.append(record)
for suffix,value in [('frames',frames),('requests',requests),('control-responses',responses)]:
 with (p/(label+'-'+suffix+'.json')).open('x') as f:json.dump(value,f,indent=2)
poses=[x['data']['frame'] for x in frames if x['data'].get('frame')]
def controlled_position(frame):
 body=next(pose for pose in frame['poses'] if str(pose['body'])=='2')
 return body['position']
summary={'frames':len(poses),'position_first':controlled_position(poses[0]) if poses else None,
 'animation':cadence,
 'position_last':controlled_position(poses[-1]) if poses else None,
 'last_feedback':poses[-1].get('control_state') if poses else None,
 'contact_bodies':sorted({body for frame in poses for body in ['1','3','4']
  if 'contact('+body+',' in frame.get('control_state',{}).get('result','')}),
 'signed_control_requests':sum('/api/goals/control' in r['url'] for r in requests),
 'accepted_control_responses':sum(r.get('result')=='ok' for r in responses),
 'refused_control_responses':sum(r.get('result')=='fail' for r in responses),
 'status':state['text']}
with (p/(label+'-summary.json')).open('x') as f:json.dump(summary,f,indent=2)
print(json.dumps(summary))
