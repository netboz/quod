import assert from 'node:assert/strict'
import test from 'node:test'
import { readWorldLibrary, spaceLibraryController } from '../src/space-library.js'
import { createKeyProvider, b64url, fromB64url } from '../src/key-provider.js'
import { memoryOperationJournal } from '../src/operation-journal.js'
import { atom, binary, compound, list, renderTerm } from '../src/prolog-term.js'

const bytes = n => new Uint8Array(32).fill(n)
const text = value => binary(new TextEncoder().encode(value))
const reference = { namespace: 'user:one/lobby', anchor: bytes(5) }
const agent = { namespace: 'user:one', anchor: bytes(4), instanceText: 'me.' }
const row = (id, name = 'Quiet Reach', owner = reference) => compound('world', [
  compound('entity_ref', [text(owner.namespace), binary(owner.anchor), compound('world', [text(id)])]), text(name),
])
const catalogue = (rows = [row('a'), row('b')], state = 'configured') => ({ result: 'ok',
  bindings: [{ Worlds: renderTerm(list(rows)), State: state }] })
const prepared = { result: 'ok', bindings: [{ Preparation: renderTerm(compound('prepared', [
  compound('agent_instance_ref', [text('node:one'), binary(bytes(8)), atom('host')]), binary(bytes(9)),
])) }] }
const ready = { result: 'ok', bindings: [{ Preparation: 'ready' }] }
const navigation = { result: 'ok', bindings: [{ Modes: '[playing]' }],
  dependencies: [{ ns: reference.namespace, genesis_anchor: b64url(reference.anchor), height: '1' }] }
const view = { title: 'My worlds', fields: Object.entries({ world: 'catalogue_selection', status: 'text_box',
  create: 'button', enter: 'button', settings: 'button', edit: 'button', refresh: 'button', setup: 'button',
  resolve: 'button', return: 'button' }).map(([role, kind]) => ({ role, kind, label: role })) }
function deferred() { let resolve; const promise = new Promise(r => { resolve = r }); return { promise, resolve } }
const requestText = body => new TextDecoder().decode(fromB64url(body.request))
async function fixture(post = async () => ready) {
  const identity = { provider: await createKeyProvider(), networkId: bytes(1),
    session: { session_id: 'session', expires_ms: Date.now() + 60000 } }
  const journal = memoryOperationJournal(), entered = [], questions = []
  const options = { journal, post: async (url, body) => {
    const request = requestText(body)
    if (url === '/api/goals/read' && request.includes('world_library_status')) return catalogue()
    if (url === '/api/goals/read' && request.includes('space_navigation')) return navigation
    return post(url, body)
  } }
  const callbacks = { close() {}, return() {}, enter: (...args) => entered.push(args), question: q => questions.push(q) }
  const open = (overrides = {}, acting = agent) => spaceLibraryController(identity, acting, reference, view, callbacks, { ...options, ...overrides })
  return { identity, journal, entered, questions, options, open }
}

test('catalogue identities include anchors and instances; duplicate labels are allowed', () => {
  const rows = readWorldLibrary(renderTerm(list([row('a'), row('b')])))
  assert.equal(rows[0].label, rows[1].label)
  assert.notEqual(rows[0].key, rows[1].key)
  assert.throws(() => readWorldLibrary(renderTerm(list([row('a'), row('a')]))), /Duplicate world identity/)
  assert.notEqual(rows[0].key, readWorldLibrary(renderTerm(list([row('a', 'Quiet Reach', {
    ...reference, anchor: bytes(7),
  })])))[0].key)
})

test('entry rechecks navigation and reuses an already initialized world without a write', async () => {
  const f = await fixture(async url => { assert.equal(url, '/api/goals/read'); return ready })
  const controller = f.open()
  await controller.ready
  controller.current.edit('world', controller.current.choices.world[1].value)
  await controller.current.invoke('enter')
  assert.equal(f.entered.length, 1)
  assert.equal(renderTerm(f.entered[0][0].instance), renderTerm(compound('world', [text('b')])))
  assert.deepEqual(await f.journal.list(), [])
  controller.close()
})

test('an authored agent term stays in the signed parser grammar rather than the binding reader', async () => {
  const f = await fixture()
  const controller = f.open({}, { ...agent, instanceText: 'people:explorer.' })
  await controller.ready
  assert.equal(controller.current.enabled.create, true)
  controller.close()
})

test('closing during preparation prevents initialization and a late navigation callback', async () => {
  const started = deferred(), preparation = deferred()
  const f = await fixture(async url => {
    assert.equal(url, '/api/goals/read')
    started.resolve(); return preparation.promise
  })
  const controller = f.open()
  await controller.ready
  const entering = controller.current.invoke('enter')
  await started.promise
  controller.close(); preparation.resolve(prepared)
  await entering
  assert.deepEqual(f.entered, [])
  assert.deepEqual(await f.journal.list(), [])
})

test('a HUD refresh shares current work; a lost initializer is resolved without resubmission', async () => {
  const started = deferred(), submitted = deferred()
  let executions = 0
  const f = await fixture(async url => {
    if (url === '/api/goals/read') return prepared
    assert.equal(url, '/api/goals/execute'); executions++
    started.resolve(); await submitted.promise
    throw Object.assign(new Error('reply lost'), { outcomeUnknown: true })
  })
  const controller = f.open()
  await controller.ready
  const entering = controller.current.invoke('enter')
  await started.promise
  assert.equal(controller.refresh(), entering)
  submitted.resolve(); await entering
  assert.equal(controller.current.enabled.enter, false)
  const [operation] = await f.journal.list()
  assert.equal(operation.context.action, 'enter')
  controller.close()
  const recovered = f.open({ post: async (url, body) => {
    if (url === '/api/goals/outcomes') {
      assert.equal(body.request, operation.request); assert.equal(body.signature, operation.signature)
      return { result: 'operation_outcome', terminal: true, status: 'committed', bindings: [{}] }
    }
    assert.equal(url, '/api/goals/read')
    if (requestText(body).includes('physics_preparation')) return ready
    return f.options.post(url, body)
  } })
  await recovered.ready
  assert.equal(recovered.current.enabled.resolve, true)
  await recovered.current.invoke('resolve')
  await recovered.current.invoke('enter')
  assert.equal(executions, 1)
  assert.equal(f.entered.length, 1)
  assert.deepEqual(await f.journal.list(), [])
  recovered.close()
})

test('closing while a form request is being signed prevents its journal and network submission', async () => {
  const started = deferred(), signing = deferred()
  const f = await fixture(async () => assert.fail('no write expected'))
  const original = f.identity.provider.sign.bind(f.identity.provider)
  f.identity.provider.sign = async bytes => {
    if (new TextDecoder().decode(bytes).includes('world_library_open')) {
      started.resolve(); await signing.promise
    }
    return original(bytes)
  }
  const controller = f.open()
  await controller.ready
  const opening = controller.current.invoke('create')
  await started.promise
  controller.close(); signing.resolve(); await opening
  assert.deepEqual(await f.journal.list(), [])
  assert.deepEqual(f.questions, [])
})

for (const [label, outcome, message] of [
  ['failed endpoint', () => { throw new Error('Outcome service unavailable.') }, /Outcome service unavailable/],
  ['nonterminal reply', () => ({ result: 'operation_outcome', terminal: false, status: 'unknown' }), /Outcome still unknown/],
  ['invalid committed form', () => ({ result: 'operation_outcome', terminal: true, status: 'committed', bindings: [{}] }), /Question|form|binding/i],
]) {
  test(`saved form resolution reports ${label} and retains its original journal identity`, async () => {
    let submissions = 0
    const f = await fixture(async url => {
      assert.equal(url, '/api/goals/execute'); submissions++
      throw Object.assign(new Error('reply lost'), { outcomeUnknown: true })
    })
    const controller = f.open()
    await controller.ready
    await controller.current.invoke('create')
    const [saved] = await f.journal.list()
    controller.close()
    const recovered = f.open({ post: async (url, body) => {
      if (url !== '/api/goals/outcomes') return f.options.post(url, body)
      assert.equal(body.request, saved.request)
      assert.equal(body.signature, saved.signature)
      return outcome()
    } })
    await recovered.ready
    await recovered.current.invoke('resolve')
    assert.match(recovered.current.values.status, message)
    assert.equal(recovered.current.enabled.resolve, true)
    assert.equal(recovered.current.enabled.create, false)
    assert.equal(submissions, 1)
    assert.equal((await f.journal.list())[0].id, saved.id)
    recovered.close()
  })
}

test('a returned foreign world or failed catalogue does not enable setup or creation', async () => {
  const f = await fixture()
  const controller = f.open({ post: async url => {
    assert.equal(url, '/api/goals/read')
    return catalogue([row('a', 'Elsewhere', { ...reference, anchor: bytes(99) })])
  } })
  await controller.ready
  assert.match(controller.current.values.status, /another library/)
  assert.equal(controller.current.enabled.setup, false)
  assert.equal(controller.current.enabled.create, false)
  assert.deepEqual(await f.journal.list(), [])
  controller.close()
})

test('revoking a listed world before entry prevents initialization', async () => {
  const f = await fixture(async () => assert.fail('no initialization expected'))
  let reads = 0
  const controller = f.open({ post: async url => {
    assert.equal(url, '/api/goals/read')
    return catalogue(++reads === 1 ? [row('a')] : [])
  } })
  await controller.ready
  await controller.current.invoke('enter')
  assert.match(controller.current.values.status, /no longer available/)
  assert.deepEqual(f.entered, [])
  controller.close()
})
