from pathlib import Path
import json,base64
import browser as b
p=Path(__file__).resolve().parent
def capture(label):
 script="""const done=arguments[0];import('/assets/engineStore-B7HFbPTa.js').then(m=>{const S=Object.values(m).find(x=>x?.Instances);const scene=S.Instances.find(e=>e.scenes.length)?.scenes[0];const nodes=[...scene.transformNodes,...scene.meshes].filter(n=>/hinged|console|roof|floor/.test(n.name));done({frame:quod36Capture.latest,nodes:nodes.map(n=>({name:n.name,parent:n.parent?.name,position:n.position.asArray(),rotation:n.rotationQuaternion?.asArray()??n.rotation.asArray(),absolute:n.getAbsolutePosition().asArray(),metadata:n.metadata})),camera:scene.activeCamera.position.asArray(),frames:quod36Capture.frames})}).catch(e=>done({error:String(e),stack:e.stack}))"""
 a=b.command('/execute/async',{'script':script,'args':[]})
 with (p/(label+'.rendered.json')).open('x') as f:json.dump(a,f,indent=2)
 screenshot=b.command('/screenshot',method='GET')
 with (p/(label+'.png')).open('xb') as f:f.write(base64.b64decode(screenshot))
 return a
if __name__=='__main__':
 import sys
 r=capture(sys.argv[1]);print(json.dumps({'nodes':r['nodes'],'frames':len(r['frames'])})[:2400])
