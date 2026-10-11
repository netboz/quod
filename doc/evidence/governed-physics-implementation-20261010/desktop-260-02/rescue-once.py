from pathlib import Path
import json,sys
import browser as b
import signed as s

p=Path(__file__).resolve().parent
def cdp(cmd,params):return b.command('/goog/cdp/execute',{'cmd':cmd,'params':params})
b.evaluate('quod27Observe.dispose()')
proto=cdp('Runtime.evaluate',{'expression':'WebSocket.prototype','returnByValue':False})['result']['objectId']
objects=cdp('Runtime.queryObjects',{'prototypeObjectId':proto})['objects']['objectId']
observed=cdp('Runtime.callFunctionOn',{'objectId':objects,'functionDeclaration':(p/'observe.js').read_text(),'returnByValue':True})
assert observed['result'].get('value',{}).get('attached'),observed
for obj in [proto,objects]:cdp('Runtime.releaseObject',{'objectId':obj})

events=[row['data'] for row in json.loads((p/'rescue-refresh-log.json').read_text())['frames']]
for row in b.command('/log',{'type':'performance'}):
 message=json.loads(row['message'])['message']
 if message['method']=='Network.webSocketFrameReceived':
  try:payload=json.loads(message['params']['response']['payloadData'])
  except (ValueError,KeyError):continue
  if payload.get('type') in ['projection','simulation_frame','refresh','unavailable']:events.append(payload)
projection=next(row for row in reversed(events) if row['type']=='projection')
frame=next(row['frame'] for row in reversed(events) if row.get('view')==projection['view'] and 'frame' in row)
assert projection['selection']=='active' and 'controlled_agent(pilot,2,2,1,' in projection['control']
assert int(projection['expires_ms']) > b.evaluate('return Date.now()')+3000,'view too close to expiry'
assert not b.evaluate('return !!document.pointerLockElement'),'user is moving; leave control to user'
sequence=int(frame['control_state']['sequence'])+1
with (p/'rescue-current-projection.json').open('x') as f:json.dump({'projection':projection,'frame':frame,'sequence':sequence},f,indent=2)
goal=s.run('rescue-reposition-goal','moveGoal',frame,projection['control'],str(sequence),'reposition(pose(vector(0,760,2800),rotation(0,0,0)))')
assert isinstance(goal,str),goal
reply=s.run('rescue-reposition-submission','control',goal)
print(json.dumps({'sequence':sequence,'submission':reply}),flush=True)
assert reply.get('result')=='ok',reply
result=b.command('/execute/async',{'script':'const done=arguments[arguments.length-1];quod27Observe.wait({sequence:arguments[0]}).then(done)','args':[str(sequence)]})
with (p/'rescue-reposition-mechanical.json').open('x') as f:json.dump(result,f,indent=2)
print(json.dumps(result),flush=True)
assert result.get('frame',{}).get('control_state',{}).get('result','').startswith('clear('),result
position=next(row['position'] for row in result['frame']['poses'] if row['body']=='2')
assert abs(position[0])<0.01 and 0.74<position[1]<0.77 and abs(position[2]-2.8)<0.01,position
