// Local TLS interoperability test. This is not a Quod server substitute in production.
import https from 'node:https'
import { readFileSync } from 'node:fs'
import { createPublicKey, verify } from 'node:crypto'
import assert from 'node:assert/strict'
import { binary, compound, renderTerm } from '../../src/prolog-term.js'
import { readTerm } from '../../src/prolog-read.js'
import { encodeGoalRequest } from '../../src/signed-client.js'
const [certPath, keyPath, mode] = process.argv.slice(2)
const onboarding = mode === "onboarding"
const corpus = JSON.parse(readFileSync(new URL('../../test/fixtures/native-contract/contracts.json', import.meta.url)))
let signingPublic = onboarding ? null : corpus.public_key
let publicKey
const bytes = s => Buffer.from(s, 'base64url')
let nonce, expiry, reads = 0, authenticated = false, writes = 0, outcomes = 0, firstRequest
const service = { namespace: 'quod:signup', anchor: Buffer.alloc(32, 9).toString('base64url') }
const group = { ns: service.namespace, anchor: Buffer.alloc(32,9).toString('hex'), coordinator: '11'.repeat(32), coordinator_admission: '22'.repeat(32), group_id: '33'.repeat(32) }
const accountValue = renderTerm(compound('agent_instance_ref', [binary(new TextEncoder().encode(corpus.account.namespace)), binary(Buffer.from(corpus.account.anchor, 'base64url')), readTerm(corpus.account.instanceText.replace(/\.\s*$/, ''))]))
const server = https.createServer({ cert: readFileSync(certPath), key: readFileSync(keyPath) }, async (req, res) => {
  try {
    if (onboarding && req.url === '/api/ontologies/system') {
      assert.equal(req.method, 'GET')
      res.writeHead(200, {'content-type':'application/json'})
      res.end(JSON.stringify({network_id:corpus.account.network, ontologies:[service]})); return
    }
    assert.equal(req.method, 'POST')
    const chunks = []
    for await (const chunk of req) chunks.push(chunk)
    const body = JSON.parse(Buffer.concat(chunks))
    let reply
    if (req.url === '/api/auth/challenge') {
      if (signingPublic === null) signingPublic = body.public_key
      assert.equal(body.public_key, signingPublic)
      publicKey = createPublicKey({key:{kty:'OKP',crv:'Ed25519',x:signingPublic},format:'jwk'})
      nonce = bytes(body.client_nonce)
      assert.equal(nonce.length, 32)
      expiry = Date.now() + 60000
      reply = { ...corpus.challenge.value, expires_ms: expiry }
    } else if (req.url === '/api/auth/complete') {
      const challenge = corpus.challenge.value
      const deadline = Buffer.alloc(8); deadline.writeBigUInt64BE(BigInt(expiry))
      const signed = Buffer.concat([Buffer.from('quod.agent.challenge.v1\0'), bytes(challenge.network_id), bytes(challenge.node_key), bytes(challenge.challenge_id), bytes(signingPublic), nonce, bytes(challenge.server_nonce), deadline])
      assert(verify(null, signed, publicKey, bytes(body.signature)))
      authenticated = true
      reply = { session_id: 'fixture-session', expires_ms: Date.now() + 600000 }
    } else if (['/api/goals/read','/api/goals/execute','/api/goals/outcomes'].includes(req.url)) {
      assert(authenticated)
      assert.equal(body.session_id, 'fixture-session')
      const request = bytes(body.request)
      assert(verify(null, request, publicKey, bytes(body.signature)))
      const domainLength = Buffer.byteLength('quod.agent.goal.v1\0')
      const operation = request.subarray(domainLength + 64, domainLength + 96)
      let at = domainLength + 96
      const nsLength = request.readUInt16BE(at); at += 2 + nsLength + 32
      const instanceLength = request.readUInt32BE(at); at += 4 + instanceLength
      const execute = req.url !== '/api/goals/read'
      assert.equal(request[at++], execute ? 1 : 0); assert.equal(request[at++], 3)
      const notAfterMs = request.readBigUInt64BE(at); at += 8
      assert(notAfterMs > BigInt(Date.now()) && notAfterMs <= BigInt(Date.now() + 30000))
      const length = request.readUInt32BE(at); at += 4
      const goal = request.subarray(at, at + length).toString()
      let account = corpus.account
      if (execute && (writes === 0 || req.url.endsWith('/outcomes'))) {
        account = {...service, instanceText: renderTerm(compound('signup',[binary(bytes(signingPublic))])) + '.'}
      }
      assert.deepEqual(request, Buffer.from(encodeGoalRequest({ networkIdentity: bytes(corpus.account.network), signingPublicKey: bytes(signingPublic), operationId: operation, agentNamespace: account.namespace, agentAnchor: bytes(account.anchor), agentInstanceText: account.instanceText, mode: execute ? 'execute' : 'read', notAfterMs, goal })))
      if (!execute) {
        assert.equal(goal, reads % 2 === 0 ? 'lobby_reference(Lobby).' : corpus.lobbyGoal)
        reply = { result:'ok', height:'1', bindings:[reads++ % 2 === 0 ? {Lobby:corpus.lobbyBinding} : {Modes:'[playing]',Scene:corpus.marks[0].text}] }
      } else {
        assert(onboarding)
        if (req.url.endsWith('/outcomes')) {
          outcomes++
          assert.equal(body.request, firstRequest.request)
          assert.equal(body.signature, firstRequest.signature)
          assert.deepEqual(body.outcome_ref,group)
          reply = { result:'operation_outcome',status:'committed',terminal:true,bindings:[{Account:accountValue}] }
        } else if (writes++ === 0) {
          const term=readTerm(goal.slice(0,-1));assert.equal(term.functor,'signup');assert.equal(term.args[0].value.length,32)
          assert.equal(Buffer.from(term.args[1].value).toString(),'human:'+Buffer.from(term.args[0].value).toString('base64url'))
          firstRequest=body
          reply = {result:'pending',...group}
        } else {
          assert.equal(writes,2)
          assert.equal(goal,`provision_lobby(${corpus.account.instanceText.replace(/\.\s*$/, '')}), lobby_reference(Lobby).`)
          reply={result:'ok',bindings:[{Lobby:corpus.lobbyBinding}]}
        }
      }
    } else throw new Error('unexpected endpoint: ' + req.url)
    res.writeHead(reply.result === 'pending' ? 202 : 200, { 'content-type': 'application/json' }); res.end(JSON.stringify(reply))
  } catch (error) {
    console.error(error.message); res.writeHead(400); res.end('{}'); process.exitCode = 1
  }
})
server.listen(0, '127.0.0.1', () => console.log(JSON.stringify({ port: server.address().port })))
process.stdin.resume()
process.stdin.on('data', () => {
  assert.equal(reads, onboarding ? 4 : 2)
  assert.equal(writes,onboarding ? 2 : 0)
  assert.equal(outcomes,onboarding ? 1 : 0)
  console.error(JSON.stringify({reads,writes,outcomes,pass:true}))
  server.close(() => process.exit(process.exitCode || 0))
})
