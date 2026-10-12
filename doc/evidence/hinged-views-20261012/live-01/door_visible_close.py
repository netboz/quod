from pathlib import Path
import os,json
import console as c,browser as b,capture_scene03 as cap
p=Path(__file__).resolve().parent
b.evaluate("globalThis.quod36Fetch=[];const f=fetch;globalThis.fetch=async(...a)=>{const r=await f(...a);if(String(a[0]).includes('/api/'))r.clone().json().then(x=>{quod36Fetch.push({url:String(a[0]),body:a[1]?.body,reply:x});if(quod36Fetch.length>128)quod36Fetch.shift()}).catch(()=>{});return r};return true")
c.open_console()
q='<<"human:5pU3X8evhfH09g1ctl0LRRP80zmhd6M7g8OQ7DyOeaE/lobby">>::physics_close_hinged(personal_lobby,5,1,<<"'+os.urandom(16).hex()+'">>).'
(p/'door-visible-close.goal.prolog').write_text(q+'\n')
r=c.prove('door-visible-close',q);assert 'true — committed' in r['text'],r['text'][-1000:]
c.button('Return to lobby');assert b.wait_js("document.body.innerText.includes('Physical space ready.')")
cap.capture('door-visible-close-after-accept')
print('ordinary personal console close committed')
