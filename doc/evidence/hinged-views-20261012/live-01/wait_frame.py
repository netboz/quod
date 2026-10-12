import browser as b

def wait(structure,body=None,revision=None):
 script='''const [structure,body,revision]=arguments[0],done=arguments[arguments.length-1];
 const ready=()=>{const f=globalThis.quod36Capture?.latest;return f?.structure===String(structure)&&(!body||f.poses.some(p=>p.body===String(body)&&p.revision===String(revision)))};
 let timer;const check=()=>{if(ready()){removeEventListener('quod36-frame',check);clearTimeout(timer);import('/assets/engineStore-B7HFbPTa.js').then(m=>m.t.LastCreatedScene.onAfterRenderObservable.addOnce(()=>done(true)))}};
 addEventListener('quod36-frame',check);timer=setTimeout(()=>{removeEventListener('quod36-frame',check);done({error:'frame deadline',latest:globalThis.quod36Capture?.latest})},9000);check();'''
 r=b.command('/execute/async',{'script':script,'args':[[structure,body,revision]]});assert r is True,r
