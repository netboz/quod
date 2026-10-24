import {chromium} from '../../../_build/lobby-toolkit-20260925/browser/node_modules/playwright/index.mjs'
import {mkdirSync,writeFileSync} from 'node:fs'
import {resolve,join} from 'node:path'
process.umask(0o077)
const out=resolve('_build/world-library-20261016/deployment-01/form-reproduction-01');mkdirSync(out)
const result={priorAttemptTerminal:true,priorPending:0,priorQuestions:0,priorWorlds:0,responses:[],events:[]}
const save=()=>writeFileSync(join(out,'observation.json'),JSON.stringify(result,null,2)+'\n')
const context=await chromium.launchPersistentContext(resolve('_build/world-library-20261016/desktop-deployed-02/browser'),{
 executablePath:'/home/yan/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome',headless:true,ignoreHTTPSErrors:true,viewport:{width:1440,height:1000}})
try{
 const page=context.pages()[0];page.setDefaultTimeout(60000)
 page.on('pageerror',e=>{result.events.push({type:'pageerror',message:e.message});save()})
 page.on('response',async r=>{if(new URL(r.url()).pathname.startsWith('/api/goals/'))try{
  result.responses.push({path:new URL(r.url()).pathname,status:r.status(),reply:await r.json(),at:Date.now()});save()
 }catch{}})
 page.on('websocket',s=>{
  for(const direction of ['framereceived','framesent'])s.on(direction,e=>{try{
   const m=JSON.parse(String(e.payload));if(m.type?.startsWith('gui_')){result.events.push({direction,...m,at:Date.now()});save()}
  }catch{}})
 })
 await page.goto('https://192.168.1.10:30519/')
 await page.getByText('Physical space ready.',{exact:true}).waitFor()
 await page.getByRole('button',{name:'My worlds',exact:true}).click()
 const panel=page.getByRole('region',{name:'My worlds',exact:true})
 await page.waitForFunction(()=>[...document.querySelectorAll('button')].some(b=>b.textContent==='Create world'&&!b.disabled))
 const response=page.waitForResponse(r=>new URL(r.url()).pathname==='/api/goals/execute')
 await panel.getByRole('button',{name:'Create world',exact:true}).click()
 result.openingReply=await (await response).json()
 result.inputs=await page.locator('input').evaluateAll(xs=>xs.map(x=>({label:x.getAttribute('aria-label'),value:x.value})))
 result.text=await page.locator('body').innerText();save()
 await page.screenshot({path:join(out,'form.png')})
 console.log(JSON.stringify({reply:result.openingReply,inputs:result.inputs,events:result.events},null,2))
}finally{await context.close();save()}
