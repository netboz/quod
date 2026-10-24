import assert from 'node:assert/strict'
import test from 'node:test'
import { personalGoal, resolvePersonalInstruction, resolveSignedOperations } from '../src/signed-client.js'
import { readPersonalAgent, readPersonalInstructions } from '../src/accounts.js'
import { createKeyProvider, b64url, fromB64url } from '../src/key-provider.js'
import { memoryOperationJournal } from '../src/operation-journal.js'
import { atom, binary, compound, list, renderTerm } from '../src/prolog-term.js'

const bytes = n => new Uint8Array(32).fill(n)
const text = value => binary(new TextEncoder().encode(value))
const human = { namespace: 'human:test', anchor: b64url(bytes(2)), instanceText: 'me.' }
const agent = { ...human, instanceText: 'personal.' }
const target = { namespace: 'space:chosen', anchor: b64url(bytes(4)) }
const input = { human, agent, key: bytes(3), target, goal: 'assertz(created(Ref)).' }
const decoded = body => new TextDecoder().decode(fromB64url(body.request))
const terminal = { result: 'operation_outcome', status: 'committed', terminal: true,
  bindings: [{ Ref: 'original' }] }

async function identity() {
  return { provider: await createKeyProvider(), networkId: bytes(1),
    session: { session_id: 'session', expires_ms: Date.now() + 60_000 } }
}

test('human signs one exact instruction; a lost reply is only resolved', async () => {
  const who = await identity(), journal = memoryOperationJournal(), calls = []
  await assert.rejects(personalGoal(who, input, { journal, post: async (url, body) => {
    calls.push(url)
    assert.equal(url, '/api/agents/instructions')
    assert.match(decoded(body), /personal_instruction_accept/)
    const [saved] = await journal.list()
    assert.equal(saved.request, body.request)
    assert.equal(saved.signing_key, b64url(who.provider.publicKey))
    assert.equal(saved.instruction.length, 43)
    throw Object.assign(new Error('reply lost'), { outcomeUnknown: true })
  } }), /reply lost/)
  const result = await resolveSignedOperations(who, { journal, post: async (url, body) => {
    calls.push(url)
    assert.equal(url, '/api/agents/instructions/outcomes')
    assert.match(decoded(body), /personal_instruction_lookup/)
    return terminal
  } })
  assert.deepEqual(result[0].reply.bindings, [{ Ref: 'original' }])
  assert.deepEqual(calls, ['/api/agents/instructions', '/api/agents/instructions/outcomes'])
  assert.deepEqual(await journal.list(), [])
})

test('a second device discovers the actor and instruction without a browser journal', async () => {
  const who = await identity(), id = bytes(6), request = bytes(7), signature = new Uint8Array(64).fill(8)
  const options = { post: async (url, body) => {
    if (url.endsWith('/outcomes')) return terminal
    const goal = decoded(body)
    if (goal.includes('personal_agent(')) return { result: 'ok', bindings: [{
      Agent: renderTerm(compound('agent_instance_ref', [text(human.namespace), binary(bytes(2)), atom('personal')])),
      Key: renderTerm(binary(bytes(3))),
    }] }
    assert.match(goal, /personal_instructions/)
    return { result: 'ok', bindings: [{ Instructions: renderTerm(list([
      compound('instruction', [binary(id), binary(request), binary(signature)]),
    ])) }] }
  } }
  const discovered = await readPersonalAgent(who, human, options)
  assert.equal(discovered.agent.instanceText, 'personal.')
  assert.deepEqual(discovered.key, bytes(3))
  const [instruction] = await readPersonalInstructions(who, human, options)
  assert.deepEqual(instruction.request, request)
  assert.deepEqual(await resolvePersonalInstruction(who, human, instruction.id, options), terminal)
})

test('unavailable actor and cancellation before send do not retain unsent work', async () => {
  const who = await identity(), journal = memoryOperationJournal()
  await assert.rejects(personalGoal(who, input, { journal, post: async () => {
    throw new Error('agent_unavailable')
  } }), /agent_unavailable/)
  assert.deepEqual(await journal.list(), [])
  const cancel = new AbortController()
  const cancellingJournal = { ...journal, async put(row) { await journal.put(row); cancel.abort() } }
  await assert.rejects(personalGoal(who, input, { journal: cancellingJournal, signal: cancel.signal,
    post: async () => assert.fail('cancelled before send'),
  }), { name: 'AbortError' })
  assert.deepEqual(await journal.list(), [])
})

test('cancellation after send retains the original operation and target selection is required', async () => {
  const who = await identity(), journal = memoryOperationJournal(), cancel = new AbortController()
  await assert.rejects(personalGoal(who, input, { journal, signal: cancel.signal,
    post: async (_url, _body, _method, options) => {
      assert.equal(options.signal, cancel.signal)
      cancel.abort()
      throw Object.assign(new Error('outcome unknown'), { outcomeUnknown: true })
    },
  }), /outcome unknown/)
  assert.equal((await journal.list()).length, 1)
  await assert.rejects(personalGoal(who, { ...input, target: undefined }, { journal }), /exact target/)
})

test('a pending instruction reply is retained and recovered without a second submission', async () => {
  const who = await identity(), journal = memoryOperationJournal()
  const reply = await personalGoal(who, input, { journal, post: async () =>
    ({ result: 'operation_outcome', status: 'pending', terminal: false }) })
  assert.equal(reply.result, 'pending')
  const [original] = await journal.list()
  await resolveSignedOperations(who, { journal, post: async () => {
    throw Object.assign(new Error('instruction_not_found'), { status: 404 })
  } })
  assert.equal((await journal.list())[0].instruction, original.instruction)
  await resolveSignedOperations(who, { journal, post: async url => {
    assert.equal(url, '/api/agents/instructions/outcomes')
    return terminal
  } })
  assert.deepEqual(await journal.list(), [])
})

test('an explicit post-admission refusal retires the definitely unsent instruction', async () => {
  const who = await identity(), journal = memoryOperationJournal(), previousFetch = globalThis.fetch
  globalThis.fetch = async () => ({ ok: false, status: 409,
    json: async () => ({ error: 'instruction_refused', submitted: false }) })
  try {
    await assert.rejects(personalGoal(who, input, { journal }), { message: 'instruction_refused', status: 409 })
    assert.deepEqual(await journal.list(), [])
  } finally { globalThis.fetch = previousFetch }
})
