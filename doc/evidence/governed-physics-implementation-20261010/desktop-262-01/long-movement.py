"""Bounded normal-client movement with read-only input/animation observations."""
from pathlib import Path
import base64
import json
import subprocess
import time
import browser as b

p = Path(__file__).resolve().parent
label = 'renewal-movement-01'
cycle = [('\ue013', 650), ('\ue015', 650), ('\ue012', 300), ('\ue014', 300)]
steps = cycle * 42
with (p / (label + '.intent.json')).open('x') as f:
    json.dump({'ordinary_keyboard_sequence': steps,
               'nominal_duration_ms': sum(ms for _, ms in steps)}, f, indent=2)

assert b.wait_js('document.body.innerText.includes("Physical space ready.")'), 'ordinary view is not ready'
owned = json.loads((p / 'compositor-placement.json').read_text())['browser']
clients = json.loads(subprocess.check_output(['hyprctl', '-j', 'clients'], text=True))
window = next(c for c in clients if c['pid'] == owned['pid'] and c['address'] == owned['address'])
focused = subprocess.run(['hyprctl', 'dispatch', 'hl.dsp.focus({window = '
                          + json.dumps('address:' + window['address']) + '})'],
                         capture_output=True, text=True)
assert focused.returncode == 0, (focused.stdout, focused.stderr)
if not b.evaluate('return document.pointerLockElement===document.querySelector("canvas.world-canvas")'):
    x, y = b.evaluate('return [Math.round(innerWidth*0.8),Math.round(innerHeight*0.7)]')
    b.evaluate('window.quodPointerCompletion=new Promise(resolve=>{let timer;const finish=()=>{clearTimeout(timer);document.removeEventListener("pointerlockchange",finish);document.removeEventListener("pointerlockerror",finish);resolve(document.pointerLockElement===document.querySelector("canvas.world-canvas"))};document.addEventListener("pointerlockchange",finish);document.addEventListener("pointerlockerror",finish);timer=setTimeout(finish,5000)})')
    b.command('/actions', {'actions': [{'type': 'pointer', 'id': 'mouse', 'parameters': {'pointerType': 'mouse'},
        'actions': [{'type': 'pointerMove', 'origin': 'viewport', 'x': x, 'y': y},
                    {'type': 'pointerDown', 'button': 0}, {'type': 'pointerUp', 'button': 0}]}]})
    assert b.command('/execute/async', {'script': 'const done=arguments[0];quodPointerCompletion.then(done)', 'args': []})
assert b.evaluate('return document.pointerLockElement===document.querySelector("canvas.world-canvas")')
cadence = b.command('/execute/async', {'script': '''
const done=arguments[0], ts=[]; let ended=false;
const finish=reason=>{if(ended)return;ended=true;clearTimeout(timer);
done({reason,timestamps:ts,hidden:document.hidden,focused:document.hasFocus()})};
const timer=setTimeout(()=>finish('deadline'),3000);
const frame=t=>{if(ended)return;ts.push(t);if(ts.length===9)finish('complete');
else requestAnimationFrame(frame)};requestAnimationFrame(frame);''', 'args': []})
active = json.loads(subprocess.check_output(['hyprctl', '-j', 'activewindow'], text=True))
with (p / (label + '-visibility.json')).open('x') as f:
    json.dump({'cadence': cadence, 'active_pid': active.get('pid'),
               'expected_pid': owned['pid']}, f, indent=2)
assert cadence['reason'] == 'complete' and active.get('pid') == owned['pid']

def public_network(rows):
    events, requests, responses = [], [], []
    for row in rows:
        message = json.loads(row['message'])['message']
        params = message.get('params', {})
        if message['method'] == 'Network.webSocketFrameReceived':
            try:
                data = json.loads(params['response']['payloadData'])
            except (ValueError, KeyError):
                continue
            if data.get('type') in ['projection', 'simulation_frame', 'refresh', 'unavailable']:
                events.append({'timestamp': params.get('timestamp'),
                               'request_id': params.get('requestId'), 'data': data})
        elif message['method'] == 'Network.requestWillBeSent' and '/api/' in params['request']['url']:
            requests.append({'id': params['requestId'], 'timestamp': params.get('timestamp'),
                             'wallTime': params.get('wallTime'),
                             'method': params['request']['method'],
                             'url': params['request']['url'].split('?')[0]})
        elif message['method'] == 'Network.responseReceived' and '/api/goals/control' in params['response']['url']:
            responses.append({'id': params['requestId'], 'timestamp': params.get('timestamp'),
                              'status': params['response']['status']})
    return {'events': events, 'requests': requests, 'responses': responses}

with (p / (label + '-prelude.json')).open('x') as f:
    json.dump(public_network(b.command('/log', {'type': 'performance'})), f, indent=2)

started = b.command('/execute/async', {'script': '''
const done=arguments[0];
import('/assets/engineStore-B7HFbPTa.js').then(m=>{
 const scene=m.t.LastCreatedScene,camera=scene.activeCamera;
 const checkRoute=()=>{
 const pos=camera.parent.position.asArray();
 if(!(pos[0]>4 && pos[0]<6 && pos[2]>1 && pos[2]<3))
   throw Error('Body is outside the checked clear-floor test segment');
 const direction=camera.getForwardRay().direction;
 if(!(direction.z < -0.8 && Math.abs(direction.x)<0.5))
   throw Error('Heading changed before the bounded route');
 const scale=Math.hypot(direction.x,direction.z),dx=direction.x/scale,dz=direction.z/scale;
 const displacements=[[1.3*dx,1.3*dz],[-1.3*dx,-1.3*dz],[0.6*dz,-0.6*dx],[-0.6*dz,0.6*dx],[0,0]];
 const corners=[[0,0],[1.3*dx,1.3*dz],[0,0],[0.6*dz,-0.6*dx],[0,0]];
 // Bound two interrupted inputs for the next short cycle, then recheck the current pose.
 for(const a of displacements)for(const b of displacements)for(let i=1;i<corners.length;i++){
   const start=[pos[0]-a[0]-b[0]+corners[i-1][0],pos[2]-a[1]-b[1]+corners[i-1][1]];
   const end=[pos[0]-a[0]-b[0]+corners[i][0],pos[2]-a[1]-b[1]+corners[i][1]];
   const v=[end[0]-start[0],end[1]-start[1]],length=v[0]**2+v[1]**2;
   const t=length?Math.max(0,Math.min(1,-(start[0]*v[0]+start[1]*v[1])/length)):0;
   const nearest=Math.hypot(start[0]+t*v[0],start[1]+t*v[1]);
   if(Math.min(start[0],end[0])<2.7 || nearest<2.7 || Math.max(Math.hypot(...start),Math.hypot(...end))>8.3)
     throw Error('The bounded input route could leave the checked floor segment');
 }
 return direction;
 };
 const direction=checkRoute(),pos=camera.parent.position.asArray();
 const rows=[],held=new Set();let ended=false,endReason,frameId,timer;
 const record=(type,detail)=>{
   if(rows.length>=9000){finish('capacity');return;}
   rows.push({type,at:performance.timeOrigin+performance.now(),...detail});
 };
 const input=e=>{if(!['w','z','s','a','q','d','ArrowUp','ArrowDown','ArrowLeft','ArrowRight','Escape'].includes(e.key))return;
   if(e.type==='keydown')held.add(e.key);else held.delete(e.key);
   record(e.type,{key:e.key,code:e.code,repeat:e.repeat,trusted:e.isTrusted});};
 const change=e=>{const pointerLocked=document.pointerLockElement===document.querySelector('canvas.world-canvas');
   record(e.type,{focused:document.hasFocus(),hidden:document.hidden,pointerLocked});
   if(!pointerLocked || !document.hasFocus() || document.hidden)finish('capture_or_focus_lost');};
 const finish=reason=>{
   if(!ended){ended=true;endReason=reason;cancelAnimationFrame(frameId);clearTimeout(timer);
     window.removeEventListener('keydown',input,true);window.removeEventListener('keyup',input,true);
     window.removeEventListener('blur',change,true);window.removeEventListener('focus',change,true);
     document.removeEventListener('visibilitychange',change,true);
     document.removeEventListener('pointerlockchange',change,true);
   }
   return {reason:endReason,rows,held:[...held],timeOrigin:performance.timeOrigin,
     finishedAt:performance.timeOrigin+performance.now(),position:camera.parent.position.asArray()};
 };
 const frame=t=>{if(ended)return;record('frame',{timestamp:t,held:[...held],
   position:camera.parent.position.asArray(),rotation:camera.rotation.asArray(),
   focused:document.hasFocus(),hidden:document.hidden});
   if(!ended)frameId=requestAnimationFrame(frame);};
 window.addEventListener('keydown',input,true);window.addEventListener('keyup',input,true);
 window.addEventListener('blur',change,true);window.addEventListener('focus',change,true);
 document.addEventListener('visibilitychange',change,true);
 document.addEventListener('pointerlockchange',change,true);
 globalThis.quodMovementEvidence={finish,status:()=>{if(!ended){try{checkRoute()}catch(e){finish('route_changed')}}return {ended,reason:endReason}}};
 timer=setTimeout(()=>finish('deadline'),90000);frameId=requestAnimationFrame(frame);
 done({position:pos,forward:direction.asArray(),startedAt:performance.timeOrigin+performance.now()});
}).catch(e=>done({error:String(e)}));''', 'args': []})
assert 'error' not in started, started
with (p / (label + '-started.json')).open('x') as f:
    json.dump(started, f, indent=2)
actions = []
for key, duration in cycle:
    actions.extend([{'type': 'keyDown', 'value': key}, {'type': 'pause', 'duration': duration},
                    {'type': 'keyUp', 'value': key}])
result = {'actions_returned': False}
start = time.monotonic()
try:
    result['completed_cycles'] = 0
    for _ in range(42):
        b.command('/actions', {'actions': [{'type': 'key', 'id': 'desktop', 'actions': actions}]})
        result['completed_cycles'] += 1
        status = b.evaluate('return quodMovementEvidence.status()')
        if status['ended']:
            result['observation_stopped'] = status
            break
    result['actions_returned'] = True
except Exception as error:
    result['error'] = str(error)
finally:
    result['elapsed_seconds'] = time.monotonic() - start
    try:
        b.command('/actions', method='DELETE')
        result['release_completed'] = True
    except Exception as error:
        result['release_error'] = str(error)
    with (p / (label + '-action-result.json')).open('x') as f:
        json.dump(result, f, indent=2)

observed = b.evaluate('const result=quodMovementEvidence.finish("complete");delete globalThis.quodMovementEvidence;return result')
with (p / (label + '-input-animation.json')).open('x') as f:
    json.dump(observed, f, indent=2)
network = public_network(b.command('/log', {'type': 'performance'}))
for row in network['responses']:
    try:
        raw = b.command('/goog/cdp/execute', {'cmd': 'Network.getResponseBody',
                                            'params': {'requestId': row['id']}})
        payload = json.loads(base64.b64decode(raw['body']) if raw.get('base64Encoded') else raw['body'])
        row.update({key: payload[key] for key in ['result', 'reasons', 'error'] if key in payload})
    except Exception as error:
        row['capture_error'] = type(error).__name__
with (p / (label + '-network.json')).open('x') as f:
    json.dump(network, f, indent=2)
with (p / (label + '-dom.json')).open('x') as f:
    json.dump(b.inspect(), f, indent=2)
with (p / (label + '.png')).open('xb') as f:
    f.write(base64.b64decode(b.command('/screenshot', method='GET')))
print(json.dumps({'action': result, 'observations': len(observed['rows']),
                  'held_at_end': observed['held'], 'position': observed['position'],
                  'frames': len(network['events']), 'control_responses': len(network['responses'])}))

if result.get('error') or observed['reason'] != 'complete' or result.get('completed_cycles') != 42:
    raise SystemExit(1)
