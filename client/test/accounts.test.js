import assert from 'node:assert/strict'
import test from 'node:test'
import { accountReference, createAccount, resumeAccounts, finishAccountSetup } from '../src/accounts.js'
import { createKeyProvider, b64url } from '../src/key-provider.js'
import { memoryOperationJournal } from '../src/operation-journal.js'
import { binary, atom, compound, renderTerm } from '../src/prolog-term.js'

const bytes = number => new Uint8Array(32).fill(number)
const text = value => binary(new TextEncoder().encode(value))
const account = { namespace: 'human:example', anchor: b64url(bytes(4)), instanceText: 'me.' }
const accountValue = renderTerm(compound('agent_instance_ref', [text(account.namespace), binary(bytes(4)), atom('me')]))
const lobbyValue = renderTerm(compound('ontology_ref', [text('human:example/lobby'), binary(bytes(5))]))
const signupReply = { result: 'ok', bindings: [{ Account: accountValue }] }
const lobbyReply = { result: 'ok', bindings: [{ Lobby: lobbyValue }] }
const terminal = reply => ({ ...reply, result: 'operation_outcome', status: 'committed', terminal: true })

async function fixture(post) {
  const identity = { provider: await createKeyProvider(), networkId: bytes(1),
    session: { session_id: 'session', expires_ms: Date.now() + 60000 } }
  const saved = []
  const journal = memoryOperationJournal()
  return { identity, journal, saved, options: {
    journal, post,
    fetch: async url => {
      assert.equal(url, '/api/ontologies/system')
      return { ok: true, json: async () => ({ network_id: b64url(bytes(1)),
        ontologies: [{ namespace: 'quod:signup', anchor: b64url(bytes(2)) }] }) }
    },
    storeIdentity: async provider => { saved.push(structuredClone(provider.accounts)) },
    saveReference: reference => reference,
  } }
}

test('signup and lobby use two ordinary goals with one atomic journal handoff', async () => {
  const stages = []
  const f = await fixture(async url => {
    assert.equal(url, '/api/goals/execute')
    const rows = await f.journal.list()
    assert.equal(rows.length, 1)
    stages.push(rows[0].context.step)
    if (stages.length === 1) return signupReply
    assert.equal(f.saved.length, 1, 'account reference must be durable before the second submission')
    return lobbyReply
  })
  const reply = await createAccount(f.identity, f.options)
  assert.equal(reply.unresolved, 0)
  assert.deepEqual(stages, ['signup', 'lobby'])
  assert.deepEqual(accountReference(f.identity), { ...account, network: b64url(bytes(1)) })
  assert.deepEqual(await f.journal.list(), [])
})

test('lost lobby reply resolves the exact operation without another creation', async () => {
  let submitted = 0
  const f = await fixture(async url => {
    assert.equal(url, '/api/goals/execute')
    if (++submitted === 1) return signupReply
    throw Object.assign(new Error('reply lost'), { outcomeUnknown: true })
  })
  await assert.rejects(createAccount(f.identity, f.options), /reply lost/)
  const [pending] = await f.journal.list()
  assert.equal(pending.context.step, 'lobby')
  const result = await resumeAccounts(f.identity, { ...f.options, post: async (url, body) => {
    assert.equal(url, '/api/goals/outcomes')
    assert.equal(body.request, pending.request)
    assert.equal(body.signature, pending.signature)
    return terminal(lobbyReply)
  } })
  assert.equal(result.unresolved, 0)
  assert.equal(submitted, 2)
})

test('failure to save a returned account retains signup recovery evidence', async () => {
  const f = await fixture(async () => signupReply)
  await assert.rejects(createAccount(f.identity, { ...f.options,
    storeIdentity: async () => { throw new Error('storage unavailable') },
  }), /storage unavailable/)
  const [pending] = await f.journal.list()
  assert.equal(pending.context.step, 'signup')
  const calls = []
  const result = await resumeAccounts(f.identity, { ...f.options, post: async url => {
    calls.push(url)
    return url.endsWith('/outcomes') ? terminal(signupReply) : lobbyReply
  } })
  assert.equal(result.unresolved, 0)
  assert.deepEqual(calls, ['/api/goals/outcomes', '/api/goals/execute'])
})

test('a consumed parent operation cannot be handed off twice', async () => {
  const f = await fixture(async () => {
    throw Object.assign(new Error('reply lost'), { outcomeUnknown: true })
  })
  await assert.rejects(createAccount(f.identity, f.options), /reply lost/)
  const [parent] = await f.journal.list()
  const child = { ...parent, id: b64url(bytes(8)), context: { flow: 'account', step: 'lobby' } }
  await f.journal.replace(parent.id, child)
  await assert.rejects(f.journal.replace(parent.id, { ...child, id: b64url(bytes(9)) }), /already advanced/)
  assert.deepEqual((await f.journal.list()).map(row => row.id), [child.id])
})


test('explicitly refused lobby setup can be finished without creating another account', async () => {
  let submitted = 0
  const f = await fixture(async () => {
    if (++submitted === 1) return signupReply
    throw new Error('signed_target_unavailable')
  })
  await assert.rejects(createAccount(f.identity, f.options), /signed_target_unavailable/)
  assert.deepEqual(await f.journal.list(), [])
  const reference = accountReference(f.identity)
  let stage
  await finishAccountSetup(f.identity, { ...f.options, post: async url => {
    assert.equal(url, '/api/goals/execute')
    const [operation] = await f.journal.list()
    stage = operation.context.step
    return lobbyReply
  } })
  assert.equal(stage, 'lobby')
  assert.deepEqual(accountReference(f.identity), reference)
  assert.deepEqual(await f.journal.list(), [])
})

test('explicit setup action cannot replace an unknown lobby operation', async () => {
  let submitted = 0
  const f = await fixture(async () => {
    if (++submitted === 1) return signupReply
    throw Object.assign(new Error('reply lost'), { outcomeUnknown: true })
  })
  await assert.rejects(createAccount(f.identity, f.options), /reply lost/)
  const before = await f.journal.list()
  await assert.rejects(finishAccountSetup(f.identity, f.options), /unresolved operation/)
  assert.deepEqual(await f.journal.list(), before)
  assert.equal(submitted, 2)
})
