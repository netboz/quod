from pathlib import Path
import json
import browser as b
p=Path(__file__).resolve().parent
def button(text):
 e=b.command('/element',{'using':'xpath','value':"//button[normalize-space()="+json.dumps(text)+"]"})['element-6066-11e4-a52e-4f735466cecf'];return b.command('/element/'+e+'/click')
def save(label):
 r=b.inspect()
 with (p/(label+'.console.json')).open('x') as f:json.dump(r,f,indent=2)
 wire=b.evaluate('return quod36Fetch??[]')
 with (p/(label+'.fetch.json')).open('x') as f:json.dump(wire,f,indent=2)
 return r
def open_console():
 button('Open console');assert b.wait_js("!!document.querySelector('textarea')")
def prove(label,goal,accept=True):
 b.evaluate("const t=document.querySelector('textarea');Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype,'value').set.call(t,arguments[0]);t.dispatchEvent(new Event('input',{bubbles:true}));return t.value",[goal]);button('Run')
 assert b.wait_js("[...document.querySelectorAll('button')].some(x=>x.innerText==='Accept solution'&&!x.disabled)||document.body.innerText.includes('false.')||document.body.innerText.includes('Error:')")
 r=save(label+'-proof')
 if accept:
  assert any(x['text']=='Accept solution' and not x['disabled'] for x in r['buttons']),r['text'][-2000:]
  button('Accept solution')
  assert b.wait_js("[...document.querySelectorAll('button')].some(x=>x.innerText==='Run'&&!x.disabled)")
  r=save(label+'-accepted')
 return r
if __name__=='__main__':
 b.evaluate("globalThis.quod36Fetch=[];const f=fetch;globalThis.fetch=async(...a)=>{const r=await f(...a);if(String(a[0]).includes('/api/'))r.clone().json().then(x=>{quod36Fetch.push({url:String(a[0]),body:a[1]?.body,reply:x});if(quod36Fetch.length>128)quod36Fetch.shift()}).catch(()=>{});return r};return true")
 open_console();print(json.dumps(save('console-open')))
