// Production HTTPS proof for M1a. This is a test client, not a Godot adapter.
import assert from 'node:assert/strict'
import { webcrypto, createHash } from 'node:crypto'
import { readFileSync, writeFileSync } from 'node:fs'
import { createInterface } from 'node:readline'
import { authenticateKey, readSystemOntologies, signedGoal, personalGoal, resolvePersonalInstruction } from '../src/signed-client.js'
import { memoryOperationJournal } from '../src/operation-journal.js'
import { fromB64url } from '../src/key-provider.js'
import { compound, variable, atom, renderTerm } from '../src/prolog-term.js'
import { readTerm } from '../src/prolog-read.js'
import { anchoredGoal, singleBinding } from '../src/world.js'
import { operationSubject, readOperations, operationGoal } from '../src/gui-operation.js'
import { readCodeState } from '../src/prolog-edit.js'

globalThis.crypto ??= webcrypto
const [configPath, resultPath] = process.argv.slice(2)
const config = JSON.parse(readFileSync(configPath,'utf8'))
const origin = new URL(config.origin)
assert.equal(origin.hostname,'127.0.0.1'); assert.equal(origin.protocol,'https:')
const nativeFetch = globalThis.fetch
let writes = 0, lastRequest
// The shared client signs all requests. Only relative URL resolution belongs
// to this Node harness. Certificate validation stays enabled.
globalThis.fetch = (url, options) => {
  const address = new URL(url,origin)
  assert.equal(address.origin,origin.origin)
  if (['/api/goals/execute','/api/agents/instructions'].includes(address.pathname)) {
    writes++; lastRequest = JSON.parse(options.body).request
  }
  return nativeFetch(address,options)
}
const input = createInterface({input:process.stdin})[Symbol.asyncIterator]()
async function barrier(phase,fields={}) {
  process.stdout.write(JSON.stringify({phase,...fields})+'\n')
  const {value,done} = await input.next(); assert(!done)
  return JSON.parse(value)
}
async function actor(row) {
  const key = await crypto.subtle.importKey('jwk',{kty:'OKP',crv:'Ed25519',x:row.public_key,d:row.seed,ext:true},'Ed25519',false,['sign'])
  const provider = {publicKey:fromB64url(row.public_key),sign:bytes=>crypto.subtle.sign('Ed25519',key,bytes)}
  const identity = await authenticateKey(provider)
  assert.equal(Buffer.from(identity.networkId).toString('base64url'),config.network)
  const reference = {...row.agent,anchor:fromB64url(row.agent.anchor)}
  return {identity,reference,provider}
}
const [owner,other,publicReader] = await Promise.all([...config.users,config.public_reader].map(actor))
const catalogue = await readSystemOntologies(publicReader.identity)
assert.deepEqual(catalogue.map(row=>row.namespace).sort(),['quod:agent','quod:controllers','quod:gui','quod:node','quod:space','quod:user'])
const tools = {namespace:'quod:gui',anchor:fromB64url(config.gui)}
const target = owner.reference
const query = (who,ref,goal)=>signedGoal(who.identity,{mode:'read',agent:who.reference,goal:anchoredGoal(ref,goal)})
const stateGoal = compound('account_setup_state',[variable('State')])
const before = singleBinding(await query(owner,target,stateGoal),'State')
assert.equal((await query(other,target,stateGoal)).result,'fail')
const deniedSources = [target,{namespace:'quod:user',anchor:fromB64url(config.user_class)}]
for (const ref of deniedSources) {
  await assert.rejects(readCodeState(other.identity,other.reference,{tools,target:ref}))
  await assert.rejects(readCodeState(publicReader.identity,publicReader.reference,{tools,target:ref}))
}
const sourceHashes = []
for (const namespace of ['quod:gui','quod:controllers','quod:space']) {
  const row = catalogue.find(row=>row.namespace===namespace)
  const source = await readCodeState(publicReader.identity,publicReader.reference,{tools,target:{namespace,anchor:fromB64url(row.anchor)}})
  assert(!source.includes(target.namespace),'Public source enumerated private accounts')
  assert(!source.includes(config.users[0].public_key))
  sourceHashes.push({namespace,sha256:createHash('sha256').update(source).digest('hex')})
}
const agent = {...target,instanceText:'personal.'}
const key = fromB64url(config.personal_key)
const subject = operationSubject(target,'entity',atom('me'))
async function offered() {
  const reply = await query(owner,target,compound('gui_operations',[subject,variable('Offers')]))
  return readOperations(singleBinding(reply,'Offers'),subject)[0]
}
const journal = memoryOperationJournal(), retained = []
const durable = {list:()=>journal.list(),delete:id=>journal.delete(id),replace:(...args)=>journal.replace(...args),
  put:async row=>{retained.push(row);await journal.put(row)}}
async function submit(form,draft) {
  const reply = await personalGoal(owner.identity,{human:target,agent,key,target,goal:operationGoal(form,draft)},{journal:durable})
  assert.equal(reply.result,'ok','An uncertain operation must be resolved, never resubmitted')
  await barrier('settle',{request:lastRequest})
  return reply
}
const form = await offered()
assert.equal(form.name,'controller_settings'); assert.equal(form.values.controller_reset,'false')
const save = await submit(form,form.values)
const fresh = await offered()
const reset = await submit(fresh,{...fresh.values,controller_reset:'true'})
assert.notDeepEqual(save.bindings,reset.bindings)
// Reconnect from the same key, with no original device journal. Original
// instruction associations and results are queried at their existing owner.
const reconnected = {...owner,identity:await authenticateKey(owner.provider)}
const mutationsBefore = writes
for (const row of [retained[0],retained.at(-1)]) {
  const recovered = await resolvePersonalInstruction(reconnected.identity,target,row.instruction)
  assert.equal(recovered.result,'operation_outcome'); assert.equal(recovered.status,'committed')
}
assert.equal(writes,mutationsBefore)
assert.equal(singleBinding(await query(reconnected,target,stateGoal),'State'),before)
writeFileSync(resultPath,JSON.stringify({passed:true,transport:'HTTPS',certificate_validation:true,
  catalogue_count:catalogue.length,source_hashes:sourceHashes,writes,save,reset,
  original_results_recovered:2,recovery_writes:writes-mutationsBefore},null,2)+'\n')
await barrier('done')
process.exit(0)
