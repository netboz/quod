// Cross-check captured production requests using the existing browser owners.
import {readFile,writeFile} from 'node:fs/promises'
import {createPublicKey,verify} from 'node:crypto'
import assert from 'node:assert/strict'
import {encodeGoalRequest} from '../../../client/src/signed-client.js'
import {readTerm} from '../../../client/src/prolog-read.js'
const names=['production-protocol-fixtures.json','production-controller-reset-fixtures.json']
const fixtures=await Promise.all(names.map(async name=>({name,...JSON.parse(await readFile(new URL(name,import.meta.url)))})))
const dec=x=>Buffer.from(x,'base64url')
const domain=Buffer.from('quod.agent.goal.v1\0')
const summaries=[]
for(const fixture of fixtures) for(const [index,r] of fixture.requests.entries()) {
 const bytes=dec(r.request_bytes),pub=dec(r.public_key)
 const encoded=encodeGoalRequest({networkIdentity:bytes.subarray(domain.length,domain.length+32),signingPublicKey:pub,operationId:dec(r.operation_id),agentNamespace:r.namespace,agentAnchor:dec(r.anchor),agentInstanceText:r.actor,mode:r.mode,notAfterMs:r.not_after_ms,goal:r.goal})
 assert.deepEqual(Buffer.from(encoded),bytes)
 const key=createPublicKey({key:Buffer.concat([Buffer.from('302a300506032b6570032100','hex'),pub]),format:'der',type:'spki'})
 assert.ok(verify(null,bytes,key,dec(r.signature)))
 const authored=r.namespace==='host-test-node' && r.goal.startsWith('<<');
 const term=authored?{functor:'authored_hosting_goal'}:readTerm(r.goal.replace(/\.$/,''));
 const actor=readTerm(r.actor.replace(/\.$/,''))
 const op=term.functor==='gui_operation'?term.args[3].value:undefined
 summaries.push({fixture:fixture.name,index,namespace:r.namespace,mode:r.mode,actor:actor.value??actor.functor,predicate:term.functor,syntax:authored?'authored-infix-server-parser':'functional-existing-term-reader',operation:op,public_key:r.public_key,operation_id:r.operation_id,not_after_ms:r.not_after_ms,encoded_bytes:bytes.length})
}
assert.equal(summaries.length,100)
assert.ok(summaries.some(r=>r.operation==='controller_save'))
assert.ok(summaries.some(r=>r.operation==='controller_restore'))
const counts=Object.fromEntries([...new Set(summaries.map(r=>r.predicate))].map(p=>[p,summaries.filter(r=>r.predicate===p).length]))
await writeFile(new URL('production-protocol-index.json',import.meta.url),JSON.stringify({notice:'Index of disposable signed production fixtures; exact original bytes/signatures in both captured fixture files',counts,requests:summaries},null,2)+'\n')
console.log('100 production requests verified: exact browser encoding, Node Ed25519; functional goals use existing term reader, authored infix hosting uses server parser in the production tests; Save/Reset operations present')
