import assert from 'node:assert/strict'
import test from 'node:test'
import { accountReference, createAccount, resumeAccounts, finishAccountSetup } from '../src/accounts.js'
import { createKeyProvider, b64url, fromB64url } from '../src/key-provider.js'
import { memoryOperationJournal } from '../src/operation-journal.js'
import { binary, atom, compound, renderTerm } from '../src/prolog-term.js'

const bytes = n => new Uint8Array(32).fill(n)
const text = value => binary(new TextEncoder().encode(value))
const account = { namespace:'human:example', anchor:b64url(bytes(4)), instanceText:'me.' }
const ref = id => compound('agent_instance_ref',[text(account.namespace),binary(bytes(4)),atom(id)])
const storage = compound('ontology_ref',[text(account.namespace),binary(bytes(4))])
const result = compound('account',[ref('me'),ref('personal'),
  compound('entity_ref',[text(account.namespace),binary(bytes(4)),binary(new TextEncoder().encode('generated-space'))]),
  storage,binary(bytes(7)),compound('pins',[binary(bytes(8)),binary(bytes(9)),binary(bytes(10)),binary(bytes(11)),binary(bytes(12))])])
const signupReply = {result:'ok',bindings:[{Account:renderTerm(ref('me'))}]}
const setupReply = {result:'ok',bindings:[{Setup:renderTerm(result)}]}
const prepared = {result:'ok',bindings:[{Preparation:renderTerm(compound('prepared',[storage,
  compound('agent_instance_ref',[text('node:host'),binary(bytes(6)),atom('me')]),compound('prepared_key',[binary(bytes(7)),binary(new Uint8Array(64).fill(13))])]))}]}
const complete = {result:'ok',bindings:[{Preparation:renderTerm(compound('complete',[result]))}]}
const terminal = reply => ({...reply,result:'operation_outcome',status:'committed',terminal:true})
const requestText = body => new TextDecoder().decode(fromB64url(body.request))
const withPreparation = post => (url,body) => url==='/api/goals/read' ? prepared : post(url,body)
async function fixture(post) {
  const identity = {provider:await createKeyProvider(),networkId:bytes(1),session:{session_id:'session',expires_ms:Date.now()+60000}}
  const saved=[],journal=memoryOperationJournal()
  return {identity,journal,saved,options:{journal,post:withPreparation(post),
    fetch:async url=>{assert.equal(url,'/api/ontologies/system');return {ok:true,json:async()=>({network_id:b64url(bytes(1)),ontologies:[{namespace:'quod:user',anchor:b64url(bytes(2))}]})}},
    storeIdentity:async provider=>saved.push(structuredClone(provider.accounts)),saveReference:reference=>reference}}
}

test('signup retains its receipt through preparation and hands off once to atomic U/A/S0 setup',async()=>{
  const stages=[]
  const f=await fixture(async(url,body)=>{
    assert.equal(url,'/api/goals/execute')
    const rows=await f.journal.list();assert.equal(rows.length,1)
    const step=rows[0].context.step;stages.push(step)
    if(step==='signup')return signupReply
    assert.equal(f.saved.length,1)
    assert.match(requestText(body),/setup_account/)
    assert.doesNotMatch(requestText(body),/provision_lobby|personal_agent_initialize|physics_initialize/)
    return setupReply
  })
  const reply=await createAccount(f.identity,f.options)
  assert.equal(reply.unresolved,0);assert.deepEqual(stages,['signup','setup'])
  assert.deepEqual(accountReference(f.identity),{...account,network:b64url(bytes(1))})
  assert.deepEqual(await f.journal.list(),[])
})

test('lost setup reply resolves exact bytes and signature without another creation or preparation',async()=>{
  let submitted=0
  const f=await fixture(async()=>{if(++submitted===1)return signupReply;throw Object.assign(new Error('reply lost'),{outcomeUnknown:true})})
  await assert.rejects(createAccount(f.identity,f.options),/reply lost/)
  const [pending]=await f.journal.list();assert.equal(pending.context.step,'setup')
  await assert.rejects(finishAccountSetup(f.identity,f.options),/unresolved operation/)
  const resolved=await resumeAccounts(f.identity,{...f.options,post:async(url,body)=>{
    assert.equal(url,'/api/goals/outcomes');assert.equal(body.request,pending.request);assert.equal(body.signature,pending.signature)
    return terminal(setupReply)
  }})
  assert.equal(resolved.unresolved,0);assert.equal(submitted,2)
})

test('failed local account save retains original signup outcome for recovery',async()=>{
  const f=await fixture(async()=>signupReply)
  await assert.rejects(createAccount(f.identity,{...f.options,storeIdentity:async()=>{throw new Error('storage unavailable')}}),/storage unavailable/)
  const [pending]=await f.journal.list();assert.equal(pending.context.step,'signup')
  const calls=[]
  const resolved=await resumeAccounts(f.identity,{...f.options,post:withPreparation(async url=>{
    calls.push(url);return url.endsWith('/outcomes')?terminal(signupReply):setupReply
  })})
  assert.equal(resolved.unresolved,0);assert.deepEqual(calls,['/api/goals/outcomes','/api/goals/execute'])
})

test('a consumed signup handoff cannot advance twice',async()=>{
  const f=await fixture(async()=>{throw Object.assign(new Error('reply lost'),{outcomeUnknown:true})})
  await assert.rejects(createAccount(f.identity,f.options),/reply lost/)
  const [parent]=await f.journal.list(),child={...parent,id:b64url(bytes(8)),context:{flow:'account',step:'setup'}}
  await f.journal.replace(parent.id,child)
  await assert.rejects(f.journal.replace(parent.id,{...child,id:b64url(bytes(9))}),/already advanced/)
  assert.deepEqual((await f.journal.list()).map(row=>row.id),[child.id])
})

test('definite setup refusal can be explicitly retried while retaining the original U',async()=>{
  let submitted=0
  const f=await fixture(async()=>{if(++submitted===1)return signupReply;throw new Error('signed_target_unavailable')})
  await assert.rejects(createAccount(f.identity,f.options),/signed_target_unavailable/)
  assert.deepEqual(await f.journal.list(),[])
  const before=accountReference(f.identity)
  await finishAccountSetup(f.identity,{...f.options,post:withPreparation(async url=>{
    assert.equal(url,'/api/goals/execute');const [operation]=await f.journal.list();assert.equal(operation.context.step,'setup');return setupReply
  })})
  assert.deepEqual(accountReference(f.identity),before);assert.deepEqual(await f.journal.list(),[])
})

test('disconnect during preparation retains committed signup evidence and resolves it before dependent setup',async()=>{
  const f=await fixture(async()=>signupReply)
  await assert.rejects(createAccount(f.identity,{...f.options,post:async url=>{
    if(url==='/api/goals/read')throw new Error('connection lost during custody preparation')
    return signupReply
  }}),/connection lost/)
  const [pending]=await f.journal.list();assert.equal(pending.context.step,'signup')
  const calls=[]
  const resolved=await resumeAccounts(f.identity,{...f.options,post:async(url,body)=>{
    calls.push(url)
    if(url==='/api/goals/outcomes'){assert.equal(body.request,pending.request);return terminal(signupReply)}
    assert.equal(url,'/api/goals/read');return complete
  }})
  assert.equal(resolved.unresolved,0);assert.deepEqual(calls,['/api/goals/outcomes','/api/goals/read'])
})

test('a fresh device with the same account reads complete source state without writes or a journal',async()=>{
  const f=await fixture(async()=>assert.fail('unexpected write'))
  f.identity.provider.accounts=[{...account,network:b64url(bytes(1))}]
  const reply=await finishAccountSetup(f.identity,{...f.options,post:async(url,body)=>{
    assert.equal(url,'/api/goals/read');assert.match(requestText(body),/account_setup_preparation/);return complete
  }})
  assert.equal(reply.result,'ok');assert.deepEqual(await f.journal.list(),[])
  const repeat=await resumeAccounts(f.identity,{...f.options,post:async()=>assert.fail('unchanged reconnect made a request')})
  assert.equal(repeat.unresolved,0)
})

test('setup refuses a result with replacement actor or owner references and retains recovery evidence',async()=>{
  const wrong=structuredClone(result);wrong.args[1]=ref('me')
  const f=await fixture(async()=>{const [row]=await f.journal.list();return row.context.step==='signup'?signupReply:{result:'ok',bindings:[{Setup:renderTerm(wrong)}]}})
  await assert.rejects(createAccount(f.identity,f.options),/different identities/)
  const [pending]=await f.journal.list();assert.equal(pending.context.step,'setup')
})


test('setup rejects replacement storage and retains its exact recovery operation',async()=>{
  const wrong=structuredClone(result);wrong.args[3]=compound('ontology_ref',[text('foreign'),binary(bytes(4))])
  const f=await fixture(async()=>{const [row]=await f.journal.list();return row.context.step==='signup'?signupReply:{result:'ok',bindings:[{Setup:renderTerm(wrong)}]}})
  await assert.rejects(createAccount(f.identity,f.options),/different storage/)
  const [pending]=await f.journal.list();assert.equal(pending.context.step,'setup')
})
