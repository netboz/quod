from pathlib import Path
import base64,json
import browser as b
p=Path(__file__).resolve().parent
def capture(label):
 events=[]
 for row in b.command('/log',{'type':'performance'}):
  m=json.loads(row['message'])['message'];v=m.get('params',{})
  if m['method']=='Network.webSocketFrameReceived':
   try:data=json.loads(v['response']['payloadData'])
   except (ValueError,KeyError):continue
   if data.get('type') in ['projection','simulation_frame','refresh','unavailable']:
    events.append({'timestamp':v.get('timestamp'),'request_id':v.get('requestId'),'data':data})
 camera=b.command('/execute/async',{'script':"const done=arguments[0];import('/assets/engineStore-B7HFbPTa.js').then(m=>{const s=m.t.LastCreatedScene,c=s.activeCamera;done({position:c.position.asArray(),rotation:c.rotation.asArray(),parent:c.parent?.position.asArray(),parentRotation:c.parent?.rotationQuaternion?.asArray(),inputs:Object.keys(c.inputs.attached),marks:s.meshes.map(x=>({id:x.id,name:x.name,parent:x.parent?.id}))})}).catch(e=>done({error:String(e)}))",'args':[]})
 state=b.inspect();record={'events':events,'camera':camera,'dom':state}
 with (p/(label+'.json')).open('x') as out:json.dump(record,out,indent=2)
 (p/(label+'.png')).write_bytes(base64.b64decode(b.command('/screenshot',method='GET')))
 frames=[r['data']['frame'] for r in events if r['data'].get('frame')]
 positions=[x['position'] for x in frames[-1]['poses'] if str(x['body'])=='2'] if frames else []
 return {'events':len(events),'latest_body2':positions,'camera':camera,'text':state['text']}
