import assert from 'node:assert/strict'
import test from 'node:test'
import { accountReference, createAccount, resumeAccounts, finishAccountSetup } from '../src/accounts.js'
import { createKeyProvider, b64url, fromB64url } from '../src/key-provider.js'
import { memoryOperationJournal } from '../src/operation-journal.js'
import { binary, atom, compound, renderTerm } from '../src/prolog-term.js'
import { readTerm } from '../src/prolog-read.js'

const bytes = number => new Uint8Array(32).fill(number)
const text = value => binary(new TextEncoder().encode(value))
const account = { namespace: 'human:example', anchor: b64url(bytes(4)), instanceText: 'me.' }
const accountValue = renderTerm(compound('agent_instance_ref', [text(account.namespace), binary(bytes(4)), atom('me')]))
const lobbyValue = renderTerm(compound('ontology_ref', [text('human:example/lobby'), binary(bytes(5))]))
const signupReply = { result: 'ok', bindings: [{ Account: accountValue }] }
const lobbyReply = { result: 'ok', bindings: [{ Lobby: lobbyValue }] }
const terminal = reply => ({ ...reply, result: 'operation_outcome', status: 'committed', terminal: true })
const setup = state => renderTerm(state)
const navigation = { result: 'ok', bindings: [{
  Lobby: renderTerm(compound('entity_ref', [text('human:example/lobby'), binary(bytes(5)), atom('personal_lobby')])),
  Modes: '[playing]',
}], dependencies: [{ ns: 'human:example/lobby', genesis_anchor: b64url(bytes(5)), height: '1' }] }
const navigating = body => new TextDecoder().decode(fromB64url(body.request)).includes('lobby_navigation')
const ready = { result: 'ok', bindings: [{ Preparation: setup(atom('ready')) }] }
const withReadyLobby = post => (url, body) => url === '/api/goals/read' ? (navigating(body) ? navigation : ready) : post(url, body)

async function fixture(post) {
  const identity = { provider: await createKeyProvider(), networkId: bytes(1),
    session: { session_id: 'session', expires_ms: Date.now() + 60000 } }
  const saved = []
  const journal = memoryOperationJournal()
  return { identity, journal, saved, options: {
    journal, post: withReadyLobby(post),
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
  const result = await resumeAccounts(f.identity, { ...f.options, post: withReadyLobby(async (url, body) => {
    assert.equal(url, '/api/goals/outcomes')
    assert.equal(body.request, pending.request)
    assert.equal(body.signature, pending.signature)
    return terminal(lobbyReply)
  }) })
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
  const result = await resumeAccounts(f.identity, { ...f.options, post: withReadyLobby(async url => {
    calls.push(url)
    return url.endsWith('/outcomes') ? terminal(signupReply) : lobbyReply
  }) })
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
  await finishAccountSetup(f.identity, { ...f.options, post: withReadyLobby(async url => {
    assert.equal(url, '/api/goals/execute')
    const [operation] = await f.journal.list()
    stage = operation.context.step
    return lobbyReply
  }) })
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

test('lost explicit setup reply resolves its exact request without another setup', async () => {
  let submitted = 0
  const f = await fixture(async () => ++submitted === 1 ? signupReply : lobbyReply)
  await createAccount(f.identity, f.options)
  const reference = accountReference(f.identity)
  await assert.rejects(finishAccountSetup(f.identity, { ...f.options, post: async (url, body) => {
    assert.equal(url, '/api/goals/execute')
    submitted++
    throw Object.assign(new Error('completion reply lost'), { outcomeUnknown: true })
  } }), /completion reply lost/)
  const [pending] = await f.journal.list()
  const request = new TextDecoder().decode(fromB64url(pending.request))
  assert.match(request, /State = pending\(_\)/)
  assert.match(request, /State = linked\(_\)/)
  assert.doesNotMatch(request, /complete_lobby_setup/)
  await assert.rejects(finishAccountSetup(f.identity, f.options), /unresolved operation/)
  const recovered = await resumeAccounts(f.identity, { ...f.options, post: withReadyLobby(async (url, body) => {
    assert.equal(url, '/api/goals/outcomes')
    assert.equal(body.request, pending.request)
    assert.equal(body.signature, pending.signature)
    return terminal(lobbyReply)
  }) })
  assert.equal(recovered.unresolved, 0)
  assert.equal(submitted, 3)
  assert.deepEqual(accountReference(f.identity), reference)
})

test('fresh lobby prepares custody and journals atomic physics startup after founding', async () => {
  const f = await fixture(() => { throw new Error('unexpected fixture request') })
  const stages = []
  const prepared = renderTerm(compound('prepared', [
    compound('agent_instance_ref', [text('node:host'), binary(bytes(6)), atom('me')]), binary(bytes(7)),
  ]))
  const options = { ...f.options, post: async (url, body) => {
    const [operation] = await f.journal.list()
    if (url === '/api/goals/read') {
      if (navigating(body)) return navigation
      assert.ok(['lobby', 'personal-agent'].includes(operation.context.step),
        'the previous committed handoff survives custody preparation')
      return { result: 'ok', bindings: [{ Preparation: setup(readTerm(prepared)) }] }
    }
    assert.equal(url, '/api/goals/execute')
    stages.push(operation.context.step)
    if (operation.context.step === 'signup') return signupReply
    if (operation.context.step === 'lobby') return lobbyReply
    if (operation.context.step === 'personal-agent') return { result: 'ok', bindings: [{}] }
    assert.equal(operation.context.step, 'physical')
    assert.match(new TextDecoder().decode(fromB64url(operation.request)), /physics_initialize/)
    throw Object.assign(new Error('startup reply lost'), { outcomeUnknown: true })
  } }
  await assert.rejects(createAccount(f.identity, options), /startup reply lost/)
  assert.deepEqual(stages, ['signup', 'lobby', 'personal-agent', 'physical'])
  const [pending] = await f.journal.list()
  assert.equal(pending.context.step, 'physical')
  await assert.rejects(finishAccountSetup(f.identity, options), /unresolved operation/)
  const result = await resumeAccounts(f.identity, { ...f.options, post: async (url, body) => {
    assert.equal(url, '/api/goals/outcomes', 'no repeated custody read or execute after lost reply')
    assert.equal(body.request, pending.request)
    return terminal({ result: 'ok', bindings: [{}] })
  } })
  assert.equal(result.unresolved, 0)
  assert.deepEqual(await f.journal.list(), [])
  const repeat = await resumeAccounts(f.identity, { ...f.options, post: async () => {
    assert.fail('unchanged reconnect sends no request')
  } })
  assert.equal(repeat.unresolved, 0)
})

test('disconnect during custody preparation retains the committed founding handoff', async () => {
  const f = await fixture(() => { throw new Error('unexpected fixture request') })
  let submits = 0
  await assert.rejects(createAccount(f.identity, { ...f.options, post: async (url, body) => {
    if (url === '/api/goals/read') throw new Error('connection lost during custody preparation')
    return ++submits === 1 ? signupReply : lobbyReply
  } }), /connection lost/)
  const [pending] = await f.journal.list()
  assert.equal(pending.context.step, 'lobby')
  const recovered = await resumeAccounts(f.identity, { ...f.options, post: async (url, body) => {
    if (url === '/api/goals/outcomes') {
      assert.equal(body.request, pending.request)
      return terminal(lobbyReply)
    }
    assert.equal(url, '/api/goals/read')
    return navigating(body) ? navigation : ready
  } })
  assert.equal(recovered.unresolved, 0)
  assert.equal(submits, 2, 'a known ready authority is not assigned again')
})


test('an intentionally disabled space completes setup without a physics write', async () => {
  const f = await fixture(() => { throw new Error('unexpected fixture request') })
  const stages = []
  const result = await createAccount(f.identity, { ...f.options, post: async (url, body) => {
    const [operation] = await f.journal.list()
    if (url === '/api/goals/read') {
      if (navigating(body)) return navigation
      assert.equal(operation.context.step, 'lobby')
      return { result: 'ok', bindings: [{ Preparation: setup(atom('disabled')) }] }
    }
    assert.equal(url, '/api/goals/execute')
    stages.push(operation.context.step)
    assert.notEqual(operation.context.step, 'physical')
    return operation.context.step === 'signup' ? signupReply : lobbyReply
  } })
  assert.equal(result.unresolved, 0)
  assert.deepEqual(stages, ['signup', 'lobby'])
  assert.deepEqual(await f.journal.list(), [])
})
