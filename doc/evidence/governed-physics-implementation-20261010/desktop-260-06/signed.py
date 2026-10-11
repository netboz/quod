from pathlib import Path
import json,datetime
import browser as b
root=Path(__file__).resolve().parent
def run(label,action,*args):
 p=root/label
 with p.with_suffix('.intent.json').open('x') as f:json.dump({'action':action,'args':args,'at':datetime.datetime.now(datetime.timezone.utc).isoformat()},f,indent=2)
 r=b.command('/execute/async',{'script':"const done=arguments[arguments.length-1];const action=arguments[0],args=arguments[1];Promise.resolve().then(()=>quod27Evidence[action](...args)).then(done,e=>done({error:String(e),operationId:e.operationId,outcomeUnknown:e.outcomeUnknown}))",'args':[action,list(args)]})
 with p.with_suffix('.json').open('x') as f:json.dump(r,f,indent=2)
 return r
