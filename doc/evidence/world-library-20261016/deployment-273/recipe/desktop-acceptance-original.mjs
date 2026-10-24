import {chromium} from '../../../_build/lobby-toolkit-20260925/browser/node_modules/playwright/index.mjs'
import {mkdirSync,writeFileSync,readFileSync} from 'node:fs'
import {resolve,basename,join} from 'node:path'
import {pathToFileURL} from 'node:url'
import assert from 'node:assert/strict'

process.umask(0o077)
const [label,url,metadataPath,treeArg,expectedNetworkHex]=process.argv.slice(2)
assert.match(label,/^[a-z0-9-]+$/)
const root=resolve('.'), tree=resolve(treeArg||'.')
const {readControl}=await import(pathToFileURL(join(tree,'client/src/locomotion.js')).href)
const out=join(root,'_build/world-library-20261016',label);mkdirSync(out)
const fixture=metadataPath==='none'?null:JSON.parse(readFileSync(metadataPath))
const result={desktop:true,headless:true,physicalVR:false,url,tree,events:[],samples:[],errors:[],requests:[],outcomes:[]}
const save=()=>writeFileSync(join(out,'observation.json'),JSON.stringify(result,null,2))
const context=await chromium.launchPersistentContext(join(out,'browser'),{
  executablePath:'/home/yan/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome',
  headless:true,ignoreHTTPSErrors:true,viewport:{width:1440,height:1000}})
const page=context.pages()[0];page.setDefaultTimeout(60000)
let latest,control,worldSocket
const observers=new Set()
page.on('pageerror',e=>{result.errors.push(e.message);save()})
page.on('request',r=>{const p=new URL(r.url()).pathname;if(p.startsWith('/api/'))result.requests.push({path:p,at:Date.now()})})
page.on('response',async r=>{
  if(new URL(r.url()).pathname==='/api/goals/execute')try{
    result.outcomes.push({status:r.status(),reply:await r.json(),at:Date.now()});save()
  }catch{}
})
page.on('websocket',socket=>socket.on('framereceived',event=>{
  try{
    const m=JSON.parse(String(event.payload))
    if(m.type==='projection'&&m.selection){
      result.events.push({type:m.type,selection:m.selection,world:m.frame?.world,at:Date.now()})
      if(m.selection==='active'){worldSocket=socket;control=readControl(m.control)}
    }
    if(socket===worldSocket&&m.frame)latest=m.frame
    if(socket===worldSocket&&['terrain_manifest','terrain_complete','unavailable','refresh'].includes(m.type))
      result.events.push({type:m.type,reason:m.reason,chunks:m.chunks?.length,at:Date.now()})
    for(const f of [...observers])f()
  }catch(e){result.errors.push(String(e))}
}))
await page.route('**/__acceptance_client/*.js',route=>route.fulfill({contentType:'text/javascript',
  body:readFileSync(join(tree,'client/src',basename(new URL(route.request().url()).pathname)),'utf8')}))
const pose=()=>latest?.poses.find(p=>p.body===control?.body)?.position
function waitFor(test,timeout=30000){
  if(test())return Promise.resolve()
  return new Promise((resolve,reject)=>{
    const done=()=>{if(test()){clearTimeout(timer);observers.delete(done);resolve()}}
    const timer=setTimeout(()=>{observers.delete(done);reject(Error('Physical delivery deadline: '+result.phase))},timeout)
    observers.add(done)
  })
}
async function sample(name){
  result.phase=name;result.samples.push({name,at:Date.now(),pose:pose(),frame:latest,
    inputs:await page.locator('input').evaluateAll(xs=>xs.map(x=>({label:x.getAttribute('aria-label'),value:x.value}))),
    text:await page.locator('body').innerText()});save();console.log(name)
}
async function ready(previous){
  await waitFor(()=>latest&&pose()&&(!previous||latest.world!==previous),90000)
  await page.getByText('Physical space ready.',{exact:true}).waitFor()
}
async function library(){
  await page.getByRole('button',{name:'My worlds',exact:true}).click()
  const panel=page.getByRole('region',{name:'My worlds',exact:true})
  await panel.waitFor()
  await page.waitForFunction(()=>{
    const panel=[...document.querySelectorAll('.gui-form')].find(p=>p.getAttribute('aria-label')==='My worlds')
    return panel&&[...panel.querySelectorAll('button')].some(b=>['Create world','Set up world tools'].includes(b.textContent)&&!b.disabled)
  })
  return panel
}
async function create(name,landscape,spacing){
  const panel=await library()
  const before=await panel.getByLabel('World',{exact:true}).locator('option').evaluateAll(xs=>xs.map(x=>x.value))
  await panel.getByRole('button',{name:'Create world',exact:true}).click()
  const form=page.getByRole('region',{name:'Create world',exact:true});await form.waitFor()
  await form.getByLabel('World name (optional)',{exact:true}).fill(name)
  await form.getByLabel('Landscape',{exact:true}).selectOption(landscape)
  await form.getByLabel('Ground detail',{exact:true}).selectOption(spacing)
  await form.getByRole('button',{name:'Create world',exact:true}).click()
  await page.waitForFunction(()=>!document.body.innerText.includes('Questions awaiting your attention'))
  await form.getByRole('button',{name:'Close',exact:true}).click()
  const list=await library()
  const rows=await list.getByLabel('World',{exact:true}).locator('option').evaluateAll(xs=>xs.map(x=>({name:x.textContent,key:x.value})))
  const row=rows.find(x=>!before.includes(x.key)&&(!name||x.name===name))
  assert.ok(row?.key&&row.name);result.worlds??=[];result.worlds.push({...row,landscape,spacing})
  assert.equal(new Set(result.worlds.map(x=>x.key)).size,result.worlds.length)
  await list.getByLabel('World',{exact:true}).selectOption(row.key)
  const previous=latest.world;await list.getByRole('button',{name:'Enter world',exact:true}).click()
  await ready(previous);await sample('entered '+row.name)
  return row
}
async function returnLobby(){
  const previous=latest.world
  await page.getByRole('button',{name:'Return to lobby',exact:true}).first().click()
  await ready(previous);await sample('returned to lobby')
}
async function move(key,name){
  result.phase=name;save()
  await page.locator('canvas').click({position:{x:1100,y:600}})
  await page.waitForFunction(()=>document.pointerLockElement!==null)
  const before=[...pose()],sequence=BigInt(latest.control_state.sequence)
  await page.keyboard.down(key)
  try{await waitFor(()=>BigInt(latest.control_state.sequence)>sequence&&Math.hypot(pose()[0]-before[0],pose()[2]-before[2])>=1)}
  finally{
    const stop=BigInt(latest.control_state.sequence);await page.keyboard.up(key)
    await waitFor(()=>BigInt(latest.control_state.sequence)>stop)
  }
  await sample(name);await page.evaluate(()=>document.exitPointerLock())
}
try{
  await page.goto(url)
  if(fixture){
    await page.evaluate(async m=>{
      const k=await import('/__acceptance_client/key-provider.js')
      const privateKey=await crypto.subtle.importKey('jwk',{kty:'OKP',crv:'Ed25519',x:m.public_key,d:m.seed},'Ed25519',true,['sign'])
      const publicKey=await crypto.subtle.importKey('raw',k.fromB64url(m.public_key),'Ed25519',true,['verify'])
      await k.storeActiveKeyProvider({keyPair:{privateKey,publicKey},accounts:[{network:m.network,namespace:m.namespace,anchor:m.anchor,instanceText:m.instanceText}]})
    },fixture)
    await page.reload();await page.getByRole('heading',{name:'Personal lobby',exact:true}).waitFor()
    await page.evaluate(async m=>{
      const [k,s,a,e,t]=await Promise.all(['key-provider','signed-client','accounts','space-entry','prolog-term'].map(x=>import('/__acceptance_client/'+x+'.js')))
      const i=await s.authenticateKey(await k.loadActiveKeyProvider())
      await e.initializeSpace(i,a.accountReference(i),{namespace:m.lobby_namespace,anchor:k.fromB64url(m.lobby_anchor),instance:t.atom('personal_lobby')})
    },fixture)
  }else{
    await page.getByRole('button',{name:'Create account',exact:true}).click()
  }
  await ready();await sample('personal lobby ready')
  const lobbyWorld=latest.world
  const tools=await library()
  await page.waitForFunction(()=>[...document.querySelectorAll('button')].some(b=>['Create world','Set up world tools'].includes(b.textContent)&&!b.disabled))
  if(await tools.getByRole('button',{name:'Set up world tools',exact:true}).isEnabled())
    await tools.getByRole('button',{name:'Set up world tools',exact:true}).click()
  await tools.getByRole('button',{name:'Create world',exact:true}).waitFor({state:'visible'})
  await page.waitForFunction(()=>[...document.querySelectorAll('button')].some(b=>b.textContent==='Create world'&&!b.disabled))
  await tools.getByRole('button',{name:'Close',exact:true}).click()
  const meadow=await create('','meadow','1000')
  const firstWorld=latest.world
  await move('ArrowUp','walked across meadow terrain')
  await page.screenshot({path:join(out,'meadow.png')})
  await returnLobby();assert.equal(latest.world,lobbyWorld)
  const highlands=await create('Highland Retreat','highlands','500')
  assert.notEqual(latest.world,firstWorld)
  await move('ArrowRight','walked across highland terrain')
  await page.screenshot({path:join(out,'highlands.png')})
  await returnLobby()
  const list=await library();await list.getByLabel('World',{exact:true}).selectOption(meadow.key)
  await list.getByRole('button',{name:'Enter world',exact:true}).click();await ready(lobbyWorld)
  assert.equal(latest.world,firstWorld);await sample('reentered saved generated-name world')
  await move('ArrowLeft','walked after reentry')
  await returnLobby()
  const observed=await page.evaluate(async()=>{
    const [k,s]=await Promise.all(['key-provider','signed-client'].map(x=>import('/__acceptance_client/'+x+'.js')))
    const identity=await s.authenticateKey(await k.loadActiveKeyProvider())
    return {pending:(await s.pendingSignedOperations(identity)).length,network:k.b64url(identity.networkId)}
  })
  Object.assign(result,observed)
  if(expectedNetworkHex)assert.equal(result.network,Buffer.from(expectedNetworkHex,'hex').toString('base64url'))
  assert.equal(result.pending,0);assert.deepEqual(result.errors,[])
  result.passed=true;save();writeFileSync(join(out,'PASSED.json'),JSON.stringify({passed:true,desktop:true,physicalVR:false,worlds:result.worlds,walking:true,reentry:true,normalSignedGui:true,pending:0,network:result.network},null,2))
  console.log('World library desktop acceptance passed')
}catch(e){
  result.failure=String(e);await sample('failure').catch(()=>{});await page.screenshot({path:join(out,'failure.png')}).catch(()=>{})
  writeFileSync(join(out,'STOP.json'),JSON.stringify({failure:String(e),noResubmission:true},null,2));throw e
}finally{save();await context.close()}
