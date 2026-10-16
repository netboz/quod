import {chromium} from '../lobby-toolkit-20260925/browser/node_modules/playwright/index.mjs'
import {mkdirSync,writeFileSync,readFileSync} from 'node:fs'
import assert from 'node:assert/strict'
import {readControl} from '../../client/src/locomotion.js'
process.umask(0o077)
const label=process.argv[2]??'01';assert.match(label,/^[0-9]{2}$/)
const out=`_build/movement-freeze-20261016/desktop-${label}`;mkdirSync(out)
const result={desktop:true,headless:true,physicalVR:false,events:[],samples:[],errors:[],executeRequests:0}
let latest,control,worldSocket,expectedClosure=false,monitoring=false,lastPhysicalAt=null
const observers=new Set()
const save=()=>writeFileSync(out+'/observation.json',JSON.stringify(result,null,2))
const context=await chromium.launchPersistentContext('_build/lobby-safety-20261016/deployment-01/desktop-01/browser',{executablePath:'/home/yan/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome',headless:true,ignoreHTTPSErrors:true,viewport:{width:1280,height:960}})
const page=context.pages()[0];page.setDefaultTimeout(60000)
page.on('pageerror',e=>result.errors.push(e.message))
page.on('request',r=>{const p=new URL(r.url()).pathname;if(p==='/api/goals/execute')result.executeRequests++;if(p==='/api/goals/control')result.events.push({type:'control',at:Date.now()})})
page.on('websocket',socket=>{
 socket.on('close',()=>{if(socket===worldSocket&&monitoring&&!expectedClosure){result.errors.push('Physical view disconnected');save()}})
 socket.on('framereceived',e=>{
  try{
   const m=JSON.parse(String(e.payload))
   if(m.type==='projection'&&m.selection){worldSocket=socket;result.events.push({type:'projection',view:m.view,selection:m.selection,expires:m.expires_ms,at:Date.now()});if(m.selection==='active')control=readControl(m.control)}
   if(m.frame){const at=Date.now();if(lastPhysicalAt!==null)result.longestPhysicalSilenceMilliseconds=Math.max(result.longestPhysicalSilenceMilliseconds??0,at-lastPhysicalAt);lastPhysicalAt=at;latest=m.frame;for(const f of [...observers])f()}
   if(socket===worldSocket&&(m.type==='refresh'||m.type==='unavailable'))result.errors.push(JSON.stringify(m))
   for(const f of [...observers])f()
  }catch(e){result.errors.push(String(e))}
 })
})
const pose=()=>latest?.poses.find(p=>p.body===control?.body)?.position
function waitFor(test,timeout=30000){
 if(test())return Promise.resolve()
 return new Promise((resolve,reject)=>{const done=()=>{if(test()){clearTimeout(timer);observers.delete(done);resolve()}};const timer=setTimeout(()=>{observers.delete(done);reject(Error('Expected physical delivery not received: '+result.phase))},timeout);observers.add(done)})
}
async function sample(name){result.samples.push({name,at:Date.now(),pose:pose(),frame:latest,controls:result.events.filter(e=>e.type==='control').length,ui:await page.evaluate(()=>({locked:!!document.pointerLockElement,workspaceHidden:document.querySelector('.world-workspace')?.hidden,text:document.body.innerText}))});save();console.log(name,pose())}
async function move(key,name){
 result.phase=name;save();const before=[...pose()],sequence=BigInt(latest.control_state.sequence)
 await page.keyboard.down(key)
 try{await waitFor(()=>BigInt(latest.control_state.sequence)>sequence&&Math.hypot(pose()[0]-before[0],pose()[2]-before[2])>=.4)}
 finally{const stop=BigInt(latest.control_state.sequence);await page.keyboard.up(key);await waitFor(()=>BigInt(latest.control_state.sequence)>stop)}
 await sample(name)
}
async function capture(){await page.locator('canvas').click({position:{x:1050,y:720}});await page.waitForFunction(()=>document.pointerLockElement!==null)}
async function source(){
 await page.evaluate(()=>document.exitPointerLock())
 const advanced=page.locator('details').filter({has:page.locator('summary').filter({hasText:/^Advanced$/})});if(!await advanced.evaluate(e=>e.open))await page.getByText('Advanced',{exact:true}).click()
 await page.getByLabel('Inspect',{exact:true}).selectOption({label:'quod:lobby'});await page.getByRole('button',{name:'View Prolog source',exact:true}).click();await page.waitForFunction(()=>{const e=document.querySelector('textarea[aria-label="Source code"]');return e&&!e.disabled&&e.value.length>100});await sample('source open')
}
try{
 await page.goto('https://192.168.1.10:30519/');await waitFor(()=>control?.grounded&&pose(),120000);monitoring=true
 const prior=JSON.parse(readFileSync('_build/movement-freeze-20261016/reproduce-03/observation.json','utf8')).states[0].frame;assert.equal(latest.world,prior.world,'Same exact anchored personal lobby after deployment');assert.equal(latest.authority,prior.authority)
 result.identityFence={world:latest.world,authority:latest.authority,epoch:latest.epoch,generation:latest.generation,structure:latest.structure};await sample('resumed existing lobby')
 await capture();await move('ArrowRight','movement before inspection')
 await source();result.phase='waiting for ordinary signed renewal while reading source';save()
 const count=result.events.filter(e=>e.type==='projection').length
 await waitFor(()=>result.events.filter(e=>e.type==='projection').length>count,180000)
 const projections=result.events.filter(e=>e.type==='projection');result.idleReadMilliseconds=projections.at(-1).at-projections[0].at
 assert.ok(result.idleReadMilliseconds>120000);assert.ok(result.longestPhysicalSilenceMilliseconds>60000,'The view must remain live across real physical-stream silence longer than the old timeout');assert.equal(projections.at(-1).selection,'active');await sample('idle source survived renewal');await page.screenshot({path:out+'/idle-source.png'})
 await page.getByRole('button',{name:'Return to lobby',exact:true}).click();await capture();await move('ArrowRight','movement after idle source close')
 await source();await page.getByRole('button',{name:'Return to lobby',exact:true}).click();await capture();await move('ArrowLeft','movement after repeated source close')
 await page.evaluate(()=>document.exitPointerLock());await page.getByRole('button',{name:'Open console',exact:true}).click();await page.getByRole('region',{name:'Focused console',exact:true}).waitFor();await page.getByRole('button',{name:'Return to lobby',exact:true}).click();await capture();await move('ArrowLeft','movement after console close')
 assert.deepEqual({world:latest.world,authority:latest.authority,epoch:latest.epoch,generation:latest.generation,structure:latest.structure},result.identityFence)
 assert.equal(result.executeRequests,0);assert.deepEqual(result.errors,[])
 await page.evaluate(()=>document.exitPointerLock());await page.screenshot({path:out+'/lobby.png'})
 result.passed=true;save();writeFileSync(out+'/PASSED.json',JSON.stringify({passed:true,desktop:true,physicalVR:false,executeRequests:0,idleReadMilliseconds:result.idleReadMilliseconds,longestPhysicalSilenceMilliseconds:result.longestPhysicalSilenceMilliseconds,renewal:true,repeatedSourceClose:true,consoleClose:true,sameWorld:true},null,2));console.log('Desktop idle-reading movement regression passed')
}catch(e){result.failure=String(e);await sample('failure').catch(()=>{});await page.screenshot({path:out+'/failure.png'}).catch(()=>{});writeFileSync(out+'/STOP.json',JSON.stringify({error:String(e),noResubmission:true}));throw e}
finally{expectedClosure=true;save();await context.close()}
