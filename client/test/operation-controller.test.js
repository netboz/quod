import test from 'node:test'
import assert from 'node:assert/strict'
import { operationController } from '../src/operation-controller.js'
import { operationSubject, readOperations, operationGoal } from '../src/gui-operation.js'
import { memoryOperationJournal } from '../src/operation-journal.js'
import { atom, binary, compound, list, renderTerm } from '../src/prolog-term.js'
import { b64url, fromB64url } from '../src/key-provider.js'

const bytes = n => new Uint8Array(32).fill(n)
const reference = { namespace: 'storage', anchor: bytes(2) }
const human = { namespace: 'human', anchor: b64url(bytes(1)), instanceText: 'me.' }
const subject = operationSubject(reference, 'class', atom('note'))
const d = n => renderTerm(binary(bytes(n)))
const text = value => binary(new TextEncoder().encode(value))
const projection = (revision = 3, name = 'Note', exact = subject) => `[operation_view(create,${renderTerm(exact)},${d(revision)},` +
  'component(form,form,[property(label,<<"Create note">>)],[' +
  'component(name,text_box,[property(label,<<"Name">>)],[]),' +
  `component(save,button,[property(label,<<"Save">>)],[])]),${d(4)},[field(name,<<"${name}">>)],save,[note],requires_input)]`
const result = { result: 'operation_outcome', status: 'committed', terminal: true,
  bindings: [{ Results: `[result(note,entity_ref(<<"storage">>,${d(2)},<<"original">>))]` }] }
const id = b64url(bytes(9))

async function setup(t, { journal = memoryOperationJournal(), instructions = [], submit, lookup = async () => result } = {}) {
  const identity = { networkId: bytes(5), provider: { publicKey: bytes(6), sign: async () => new Uint8Array(64) },
    session: { session_id: 'session', expires_ms: Date.now() + 120000 } }
  let socket, closes = 0, calls = []
  class Socket {
    constructor() { socket = this; this.messages = [] }
    send(raw) { this.messages.push(JSON.parse(raw)) }
    close() {}
  }
  const options = { journal, WebSocket: Socket, url: 'ws://localhost/api/views', post: async (url, body) => {
    calls.push(url)
    if (url === '/api/agents/instructions') return submit ? submit(body) : { result: 'ok', bindings: result.bindings }
    if (url.endsWith('/outcomes')) return lookup(body)
    const goal = new TextDecoder().decode(fromB64url(body.request))
    if (goal.includes('personal_instructions(')) return { result: 'ok', bindings: [{ Instructions: renderTerm(list(instructions.map(id =>
      compound('instruction', [binary(fromB64url(id)), binary(bytes(8)), binary(new Uint8Array(64))])))) }] }
    if (goal.includes('personal_agent(')) return { result: 'ok', bindings: [{
      Agent: renderTerm(compound('agent_instance_ref', [text(human.namespace),binary(bytes(1)),atom('personal')])), Key: d(7) }] }
    if (goal.includes('gui_operation_classes(')) return { result: 'ok', bindings: [{ Classes: '[note,space]' }] }
    throw new Error('unexpected read')
  } }
  const controller = operationController(identity, human, [reference], { close() { closes++ } }, options)
  t.after(() => controller.close())
  await controller.ready
  async function choose() {
    await controller.current.edit('@operation/storage', JSON.stringify(['storage', b64url(bytes(2))]))
    controller.current.edit('@operation/class', 'note')
    await project()
  }
  async function project(value = projection()) {
    if (socket.messages.length) socket.onmessage({ data: JSON.stringify({ type: 'refresh', reason: 'changed' }) })
    await socket.onopen()
    const open = socket.messages.at(-1)
    socket.onmessage({ data: JSON.stringify({ type: 'projection', kind: 'gui_operations', view: b64url(new Uint8Array(await crypto.subtle.digest('SHA-256', fromB64url(open.request)))),
      height: '1', expires_ms: String(Date.now() + 30000), value }) })
  }
  return { controller, journal, calls, choose, project, options, identity, get socket() { return socket }, get closes() { return closes } }
}

test('storage is explicit, the controller retains edits, and success cannot be repeated accidentally', async t => {
  const f = await setup(t)
  assert.equal(f.controller.current.values['@operation/storage'], '')
  assert.equal(f.calls.includes('/api/agents/instructions'), false)
  await f.choose()
  f.controller.current.edit('name', 'Shared draft')
  assert.equal(f.controller.current.values.name, 'Shared draft')
  assert.equal(f.controller.current.view.fields[3].children[0].kind, 'text_box')
  await f.controller.current.invoke('save')
  assert.match(f.controller.current.values['@operation/status'], /committed/)
  assert.match(f.controller.current.values['@operation/result'], /original/)
  assert.equal(f.controller.current.enabled.save, false)
  await f.controller.current.invoke('save')
  assert.equal(f.calls.filter(url => url === '/api/agents/instructions').length, 1)
  assert.deepEqual(await f.journal.list(), [])
  f.socket.onmessage({ data: JSON.stringify({ type: 'unavailable', reason: 'revoked' }) })
  assert.match(f.controller.current.values['@operation/status'], /committed/)
  assert.match(f.controller.current.values['@operation/form_status'], /revoked/)
  await f.project(projection(8, 'Changed schema'))
  f.controller.current.invoke('@operation/defaults')
  assert.equal(f.controller.current.enabled.save, false, 'adopting fields cannot reopen a committed draft')
  f.controller.current.invoke('@operation/defaults')
  assert.equal(f.controller.current.enabled.save, true, 'explicit fresh defaults allow another operation')
})

test('opening another subject preserves known refusal and does not re-resolve history', async t => {
  const f = await setup(t, { submit: async () => ({ result: 'fail', reasons: ['denied'] }) })
  await f.choose(); await f.controller.current.invoke('save')
  assert.match(f.controller.current.values['@operation/status'], /refused/)
  const before = f.calls.length
  const instance = operationSubject(reference, 'entity', atom('existing'))
  f.controller.open([reference], instance)
  await f.project(projection(4, 'Instance', instance).replace('requires_input', 'unavailable'))
  // Human-read availability is advisory; A's submission rechecks authority.
  assert.equal(f.controller.current.enabled.save, true)
  assert.equal(f.controller.current.view.fields[0].enabled, false)
  assert.equal(f.calls.length, before)
})

test('lost reply blocks creation, preserves the draft, and resolves only the original instruction', async t => {
  const f = await setup(t, { submit: async () => { throw Object.assign(new Error('lost'), { outcomeUnknown: true }) } })
  await f.choose(); f.controller.current.edit('name', 'Keep me')
  await f.controller.current.invoke('save')
  assert.match(f.controller.current.values['@operation/status'], /uncertain/)
  assert.equal((await f.journal.list()).length, 1)
  assert.equal(f.controller.current.enabled.save, false)
  f.controller.current.close()
  assert.equal(f.closes, 1)
  assert.equal(f.controller.current.values.name, 'Keep me')
  await f.controller.current.invoke('@operation/resolve')
  assert.match(f.controller.current.values['@operation/result'], /original/)
  assert.equal(f.controller.current.enabled.save, false)
  assert.equal(f.calls.filter(url => url === '/api/agents/instructions').length, 1)
})

test('another device with a cleared journal recovers committed history without a submit', async t => {
  const f = await setup(t, { instructions: [id] })
  assert.match(f.controller.current.values['@operation/result'], /original/)
  assert.equal(f.calls.includes('/api/agents/instructions'), false)
  assert.deepEqual(await f.journal.list(), [])
})

test('an unresolved authoritative instruction blocks a fresh device too', async t => {
  const f = await setup(t, { instructions: [id], lookup: async () => ({ result: 'pending' }) })
  await f.controller.current.edit('@operation/storage', JSON.stringify(['storage', b64url(bytes(2))]))
  assert.equal(f.controller.current.values['@operation/storage'], '')
  assert.match(f.controller.current.values['@operation/status'], /unresolved/)
})

test('interrupted recovery reuses terminal observations in the same controller', async t => {
  let lookups = 0
  const f = await setup(t, { instructions: [id, b64url(bytes(10))], lookup: async () => {
    if (++lookups === 2) throw new Error('connection lost')
    return result
  } })
  assert.equal(lookups, 2)
  await f.controller.current.invoke('@operation/refresh')
  assert.equal(lookups, 3)
  assert.equal(f.calls.includes('/api/agents/instructions'), false)
})

test('busy subject changes report refusal without changing the active draft', async t => {
  let release, started
  const entered = new Promise(resolve => { started = resolve })
  const f = await setup(t, { submit: async () => { started(); return new Promise(resolve => { release = resolve }) } })
  await f.choose(); f.controller.current.edit('name', 'Active')
  const sending = f.controller.current.invoke('save')
  await entered
  assert.equal(f.controller.open([reference], operationSubject(reference, 'entity', atom('other'))), false)
  assert.equal(f.controller.current.values.name, 'Active')
  release({ result: 'ok', bindings: result.bindings }); await sending
})

test('changed defaults preserve input; changed definitions require explicit adoption; wrong subjects refuse', async t => {
  const f = await setup(t); await f.choose(); f.controller.current.edit('name', 'Keep draft')
  await f.project(projection(3, 'New default'))
  assert.equal(f.controller.current.values.name, 'Keep draft')
  await f.project(projection(8, 'New schema'))
  assert.equal(f.controller.current.enabled.save, false)
  assert.equal(f.controller.current.values.name, 'Keep draft')
  f.controller.current.invoke('@operation/defaults')
  assert.equal(f.controller.current.values.name, 'Keep draft')
  assert.equal(f.controller.current.enabled.save, true)
  await f.project(projection(8, 'Wrong', operationSubject({ ...reference, anchor: bytes(0) }, 'class', atom('note'))))
  assert.equal(f.controller.current.enabled.save, false)
})

test('unavailable agents refuse before submission; cancellation keeps unsent draft', async t => {
  const f = await setup(t, { submit: async () => { throw new Error('agent_unavailable') } })
  await f.choose(); f.controller.current.edit('name', 'Unsent')
  await f.controller.current.invoke('save')
  assert.match(f.controller.current.values['@operation/status'], /agent_unavailable/)
  assert.equal(f.controller.current.enabled.save, true)
  assert.deepEqual(await f.journal.list(), [])
  f.controller.current.invoke('@operation/cancel')
  assert.equal(f.controller.current.values.name, 'Unsent')
})

test('the binder goal carries the exact subject, schema and only typed fields', () => {
  const [form] = readOperations(projection(), subject)
  const goal = operationGoal(form, { name: 'A' })
  assert.match(goal, /gui_operation\(class_ref/)
  assert.match(goal, /field\(name,<<"A">>\)/)
  assert.match(goal, /Results\)\.$/)
  assert.equal(goal.includes('Goal'), false)
  assert.throws(() => operationGoal(form, { name: 'A', output: 'injected' }), /Incomplete/)
})
