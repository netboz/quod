import {chromium} from '../lobby-toolkit-20260925/browser/node_modules/playwright/index.mjs'
import {mkdirSync,writeFileSync} from 'node:fs'
import {readControl} from '../../client/src/locomotion.js'
const out='_build/movement-freeze-20261016/reproduce-01';mkdirSync(out)
const result={events:[],states:[],errors:[]};let latest,control
const save=()=>writeFileSync(out+'/observation.json',JSON.stringify(result,null,2))
const context=await chromium.launchPersistentContext('_build/lobby-safety-20261016/deployment-01/desktop-01/browser',{executablePath:'/home/yan/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome',headless:true,ignoreHTTPSErrors:true,viewport:{width:1280,height:960}})
const page=context.pages()[0];page.setDefaultTimeout(30000)
page.on('pageerror',e=>result.errors.push(e.message))
page.on('request',r=>{if(new URL(r.url()).pathname.startsWith('/api/goals/control'))result.events.push({type:'control',at:Date.now()})})
page.on('websocket',socket=>{socket.on('close',()=>result.events.push({type:'ws-close',at:Date.now()}));socket.on('framereceived',e=>{try{const m=JSON.parse(String(e.payload));if(m.type==='projection'){result.events.push({type:m.type,selection:m.selection,expires:m.expires_ms,at:Date.now()});if(m.selection==='active')control=readControl(m.control)}if(m.frame)latest=m.frame;if(m.type==='unavailable'||m.type==='refresh')result.events.push(m)}catch{}})})
const pose=()=>latest?.poses.find(p=>p.body===control?.body)?.position
async function state(name){result.states.push({name,pose:pose(),frame:latest,controls:result.events.filter(e=>e.type==='control').length,ui:await page.evaluate(()=>({locked:!!document.pointerLockElement,active:document.activeElement?.tagName,text:document.body.innerText,workspaceHidden:document.querySelector('.world-workspace')?.hidden}))});save();console.log(name,pose(),result.states.at(-1).ui.locked,result.states.at(-1).controls)}
async function frames(n=60){await page.evaluate(n=>new Promise(resolve=>{function frame(){if(--n<=0)resolve();else requestAnimationFrame(frame)}requestAnimationFrame(frame)}),n)}
async function move(name){await page.keyboard.down('ArrowDown');await frames(45);await page.keyboard.up('ArrowDown');await frames(10);await state(name)}
try{
await page.goto('https://192.168.1.10:30519/');await page.getByText('Physical space ready.',{exact:true}).waitFor();await state('loaded')
await page.locator('canvas').click({position:{x:1050,y:720}});await move('initial movement')
await page.evaluate(()=>document.exitPointerLock());await page.getByText('Advanced',{exact:true}).click();const options=await page.getByLabel('Inspect',{exact:true}).locator('option').allTextContents();result.options=options;save();await page.getByLabel('Inspect',{exact:true}).selectOption({label:'quod:space'});await page.getByRole('button',{name:'View Prolog source',exact:true}).click();await page.getByLabel('Source code',{exact:true}).waitFor();await state('source open')
await page.getByRole('button',{name:'Return to lobby',exact:true}).click();await move('closed no canvas click');await page.locator('canvas').click({position:{x:1050,y:720}});await move('closed canvas clicked')
await state('final');await page.screenshot({path:out+'/final.png'});console.log('finished')
}catch(e){result.failure=String(e);await state('failure');throw e}finally{save();await context.close()}
