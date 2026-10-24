import {chromium} from '../../../_build/lobby-toolkit-20260925/browser/node_modules/playwright/index.mjs'
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs'
import {resolve,join} from 'node:path'
import {pathToFileURL} from 'node:url'
import assert from 'node:assert/strict'
process.umask(0o077)
const tree=resolve('_build/world-library-20261016/clean-integration-07/tree')
const {readControl}=await import(pathToFileURL(join(tree,'client/src/locomotion.js')).href)
const out=resolve('_build/world-library-20261016/deployment-02/reentry-diagnosis-02');mkdirSync(out)
const result={events:[],commands:[],frames:[],errors:[]},save=()=>writeFileSync(join(out,'observation.json'),JSON.stringify(result,null,2)+'\n')
const context=await chromium.launchPersistentContext(resolve('_build/world-library-20261016/desktop-deployed-03/browser'),{
 executablePath:'/home/yan/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome',headless:true,ignoreHTTPSErrors:true,viewport:{width:1440,height:1000}})
let latest,control,worldSocket,view,interest,manifest,completed
const observers=new Set(),pose=()=>latest?.poses.find(p=>p.body===control?.body)?.position
function waitFor(test){if(test())return Promise.resolve();return new Promise((resolve,reject)=>{
 const done=()=>{if(test()){clearTimeout(timer);observers.delete(done);resolve()}}
 const timer=setTimeout(()=>{observers.delete(done);reject(Error('delivery deadline'))},60000);observers.add(done)
})}
function goalText(body){
 const b=Buffer.from(JSON.parse(body).request,'base64url');let i=Buffer.byteLength('quod.agent.goal.v1\0')+96
 const ns=b.readUInt16BE(i);i+=2+ns+32;const instance=b.readUInt32BE(i);i+=4+instance+2+8
 const n=b.readUInt32BE(i);return b.subarray(i+4,i+4+n).toString('utf8')
}
try{
 const page=context.pages()[0];page.setDefaultTimeout(60000)
 await page.addInitScript(()=>{
  window.__inputEvidence=[]
  for(const type of ['keydown','keyup','pointerlockchange','blur'])document.addEventListener(type,e=>{
   queueMicrotask(()=>window.__inputEvidence.push({type,key:e.key,at:Date.now(),prevented:e.defaultPrevented,
    captured:document.pointerLockElement!==null,focus:document.activeElement?.tagName,
    status:document.querySelector('.world-panel')?.innerText}))
  },true)
 })
 page.on('pageerror',e=>{result.errors.push(e.message);save()})
 page.on('request',r=>{if(new URL(r.url()).pathname==='/api/goals/control'){
  result.commands.push({goal:goalText(r.postData()),at:Date.now()});save()
 }})
 page.on('websocket',socket=>{
  socket.on('framereceived',e=>{try{
   const m=JSON.parse(String(e.payload))
   if(m.type==='projection'&&m.selection==='active'){
    worldSocket=socket;view=m.view;interest=undefined;manifest=null;completed=null;control=readControl(m.control)
   }
   if(socket===worldSocket){
    if(m.frame){latest=m.frame;result.frames.push({at:Date.now(),world:latest.world,pose:pose(),feedback:latest.control_state});if(result.frames.length>300)result.frames.shift()}
    if(m.type==='terrain_manifest'){manifest=m;completed=null}
    if(['projection','terrain_manifest','terrain_complete','unavailable'].includes(m.type))result.events.push({type:m.type,view:m.view,token:m.token,interest:m.interest_seq,at:Date.now()})
   }
   for(const f of [...observers])f()
  }catch(e){result.errors.push(String(e))}})
  socket.on('framesent',e=>{try{
   const m=JSON.parse(String(e.payload));if(socket!==worldSocket)return
   if(m.type==='terrain_interest'){interest=m.sequence;completed=null;result.events.push({...m,at:Date.now()})}
   if(m.type==='terrain_ack'&&m.complete&&m.view===view&&m.token===manifest?.token&&manifest.interest_seq===interest){completed=m.token;result.events.push({...m,at:Date.now()})}
   for(const f of [...observers])f()
  }catch(e){result.errors.push(String(e))}})
 })
 await page.goto('https://192.168.1.10:30519/')
 await page.getByText('Physical space ready.',{exact:true}).waitFor()
 await page.getByRole('button',{name:'My worlds',exact:true}).click()
 const panel=page.getByRole('region',{name:'My worlds',exact:true})
 await panel.getByLabel('World',{exact:true}).selectOption({label:'Quiet Wilds'})
 await panel.getByRole('button',{name:'Enter world',exact:true}).click()
 for(;;){
  await waitFor(()=>completed&&pose())
  const token=completed
  await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))))
  if(completed===token)break
 }
 await page.getByText('Physical space ready.',{exact:true}).waitFor()
 result.before={pose:[...pose()],feedback:latest.control_state,completed,interest,text:await page.locator('body').innerText()};save()
 await page.evaluate(()=>{window.__captured=new Promise(resolve=>document.addEventListener('pointerlockchange',resolve,{once:true}))})
 await page.locator('canvas').click({position:{x:1100,y:600}})
 await page.evaluate(()=>window.__captured)
 await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))))
 await page.waitForFunction(()=>document.pointerLockElement!==null)
 result.domBefore=await page.evaluate(()=>window.__inputEvidence);save()
 const sequence=BigInt(latest.control_state.sequence),before=[...pose()]
 await page.keyboard.down('ArrowLeft')
 try{await waitFor(()=>BigInt(latest.control_state.sequence)>sequence&&Math.hypot(pose()[0]-before[0],pose()[2]-before[2])>=1)}
 finally{await page.keyboard.up('ArrowLeft')}
 result.domAfter=await page.evaluate(()=>window.__inputEvidence);result.after={pose:[...pose()],feedback:latest.control_state};result.passed=true;save()
 await page.screenshot({path:join(out,'after.png')})
 assert.deepEqual(result.errors,[])
 console.log(JSON.stringify({before:result.before,after:result.after,commands:result.commands.length,passed:true}))
}catch(error){result.failure=String(error);result.domAfter=await context.pages()[0].evaluate(()=>window.__inputEvidence);await context.pages()[0].screenshot({path:join(out,'failure.png')});save();throw error}
finally{await context.close();save()}
