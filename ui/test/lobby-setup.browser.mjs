import assert from 'node:assert/strict'
import {createHash} from 'node:crypto'
import {binary,compound,list,atom,renderTerm} from '../../client/src/prolog-term.js'
import {b64url} from '../../client/src/key-provider.js'

export async function checkLobbySetup(page,origin,screenshotPath) {
  let writes=0
  const text=value=>binary(new TextEncoder().encode(value))
  const anchor=new Uint8Array(32).fill(3)
  await page.route('**/lobby-setup-fixture',route=>route.fulfill({contentType:'text/html',body:'<div id="fixture"></div>'}))
  await page.route('**/api/ontologies/system',route=>route.fulfill({json:{network_id:b64url(new Uint8Array(32).fill(1)),ontologies:[]}}))
  await page.route('**/api/goals/read',route=>route.fulfill({json:{result:'ok',bindings:[{
    Lobby:renderTerm(compound('entity_ref',[text('human:setup-test/lobby'),binary(anchor),atom('personal_lobby')])),
    Modes:renderTerm(list([atom('playing')])),
  }],dependencies:[{ns:'human:setup-test/lobby',genesis_anchor:b64url(anchor),height:'1'}]}}))
  await page.route('**/api/goals/execute',route=>{writes++;return route.fulfill({json:{result:'fail'}})})
  await page.routeWebSocket('**/api/views',socket=>socket.onMessage(payload=>{
    const message=JSON.parse(String(payload))
    if(message.type!=='open')return
    if(message.view_kind==='gui_hud')socket.send(JSON.stringify({type:'unavailable',reason:'view_not_authorized_or_ready'}))
    else socket.send(JSON.stringify({type:'projection',view:createHash('sha256').update(Buffer.from(message.request,'base64url')).digest('base64url'),
      height:'1',expires_ms:String(Date.now()+60_000),marks:'[]',selection:'unavailable'}))
  }))
  await page.goto(origin+'/lobby-setup-fixture')
  const path=new URL('./lobby-setup.fixture.tsx',import.meta.url).pathname
  await page.evaluate(async path=>{
    const refresh=await import('/@react-refresh')
    refresh.default.injectIntoGlobalHook(window)
    window.$RefreshReg$=()=>{};window.$RefreshSig$=()=>type=>type
    window.__vite_plugin_react_preamble_installed__=true
    const {createLobbySetupFixture}=await import(`/@fs${path}`)
    window.lobbySetupFixture=await createLobbySetupFixture()
  },path)
  try{
    await page.getByText('The scene is unavailable. Check its setup and source.',{exact:true}).waitFor()
    const finish=page.getByRole('button',{name:'Finish account setup',exact:true})
    await finish.waitFor();assert.equal(await finish.isEnabled(),true)
    assert.equal(writes,0,'opening an incomplete lobby does not submit a repair')
    assert.equal(await page.evaluate(()=>window.lobbySetupFixture.completions()),0)
    await page.evaluate(()=>window.lobbySetupFixture.configure({unresolved:1}))
    await page.waitForFunction(()=>document.querySelectorAll('button').length&&Array.from(document.querySelectorAll('button')).some(b=>b.textContent==='Finish account setup'&&b.disabled))
    assert.equal(await finish.isDisabled(),true,'uncertain work blocks a new setup action')
    await page.evaluate(()=>window.lobbySetupFixture.configure({unresolved:0}))
    await finish.click()
    assert.equal(await page.evaluate(()=>window.lobbySetupFixture.completions()),1)
    await page.evaluate(()=>window.lobbySetupFixture.configure({owner:false}))
    await finish.waitFor({state:'detached'})
    assert.equal(writes,0)
    if(screenshotPath)await page.screenshot({path:screenshotPath,fullPage:true})
    return {ownerControl:true,uncertainBlocked:true,explicitActionOnly:true,otherAgentHidden:true,automaticWrites:writes}
  }finally{await page.evaluate(()=>window.lobbySetupFixture.dispose())}
}
