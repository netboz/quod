import { strict as assert } from 'node:assert'
import { test } from 'node:test'
import { connectGuiHud, connectGuiQuestion } from '../src/gui-view.js'
import { atom } from '../src/prolog-term.js'

function fixture(t, question = false) {
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 1800000000000 })
  let socket, opened
  const opens = [], values = [], errors = [], discarded = []
  const identity = { networkId: new Uint8Array(32), provider: {
    publicKey: new Uint8Array(32), sign: async () => new Uint8Array(64),
  }, session: { session_id: 'session', expires_ms: Date.now() + 600000 } }
  const agent = { namespace: 'human', anchor: Buffer.alloc(32).toString('base64url'), instanceText: 'human.' }
  const reference = { namespace: 'responder', anchor: new Uint8Array(32), question: atom('question') }
  class Socket {
    constructor() { socket = this; this.sent = [] }
    send(json) {
      const message = JSON.parse(json); this.sent.push(message)
      if (message.type === 'open') { opens.push(message); opened?.(message); opened = null }
    }
    receive(message) { this.onmessage({ data: JSON.stringify(message) }) }
    close() {}
  }
  const callbacks = { projection: value => values.push(value), unavailable: error => errors.push(error),
    discard: () => discarded.push(true) }
  const options = { WebSocket: Socket, url: 'ws://localhost/api/views' }
  const stream = question ? connectGuiQuestion(identity, agent, reference, callbacks, options)
    : connectGuiHud(identity, agent, callbacks, options)
  t.after(() => stream.close())
  return { stream, socket, opens, values, errors, discarded, identity,
    nextOpen: () => new Promise(resolve => { opened = resolve }),
    async project(open, value = '[]', changes = {}) {
      const view = Buffer.from(await crypto.subtle.digest('SHA-256', Buffer.from(open.request, 'base64url'))).toString('base64url')
      socket.receive({ type: 'projection', kind: question ? 'gui_question' : 'gui_hud', view,
        height: '9007199254740993', expires_ms: String(Date.now() + 30000), value, ...changes })
    },
  }
}

test('HUD uses the authenticated human scope and renews without frame credit or losing its view', async t => {
  const f = fixture(t)
  await f.socket.onopen()
  const first = f.opens[0]
  assert.equal(first.view_kind, 'gui_hud')
  assert.equal(first.view_namespace, 'human')
  assert.match(Buffer.from(first.request, 'base64url').toString(), /gui_pending_questions\(View\)/)
  await f.project(first, `[question_ref(<<"responder">>,<<"${'a'.repeat(32)}">>,q(1))]`)
  assert.equal(f.values[0][0].namespace, 'responder')
  assert.equal(f.socket.sent.length, 1, 'no physics ACK')
  const opened = f.nextOpen()
  t.mock.timers.tick(15000)
  const renewal = await opened
  assert.equal(f.discarded.length, 0)
  await f.project(renewal)
  assert.deepEqual(f.values[1], [])
  await f.project(first)
  assert.equal(f.values.length, 2, 'retired projection ignored')
  assert.deepEqual(f.errors, [])
})

test('question adapter decodes the common form model without world state', async t => {
  const f = fixture(t, true)
  await f.socket.onopen()
  assert.equal(f.opens[0].view_namespace, 'responder')
  assert.match(Buffer.from(f.opens[0].request, 'base64url').toString(), /gui_question_form\(question,View\)/)
  const digest = `<<"${'a'.repeat(32)}">>`
  const tree = 'component(form,form,[property(label,<<"Settings">>)],[' +
    'component(name,text_box,[property(label,<<"Name">>)],[]),' +
    'component(save,button,[property(label,<<"Save">>)],[])])'
  const value = `question_form(form_ref(<<"app">>,${digest},form),` +
    `agent_instance_ref(<<"responder">>,${digest},handler),${digest},awaiting,` +
    `form_view(${digest},${tree},${digest},[field(name,<<"Yan">>)],save))`
  await f.project(f.opens[0], value)
  assert.deepEqual({ ...f.values[0].values }, { name: 'Yan' })
  assert.equal(f.values[0].interaction, 'editable')
  assert.equal(f.socket.sent.length, 1)
})

for (const loss of ['expiry', 'disconnect', 'refusal']) {
  test(`HUD ${loss} discards authorization and late candidates without reconnecting`, async t => {
    const f = fixture(t)
    await f.socket.onopen(); await f.project(f.opens[0])
    const opened = f.nextOpen()
    t.mock.timers.tick(15000)
    const candidate = await opened
    if (loss === 'expiry') t.mock.timers.tick(15000)
    else if (loss === 'disconnect') f.socket.onclose()
    else f.socket.receive({ type: 'unavailable', reason: 'denied' })
    await f.project(candidate)
    assert.equal(f.values.length, 1)
    assert.equal(f.errors.length, 1)
    assert.equal(f.stream.current, null)
    t.mock.timers.tick(60000)
    assert.equal(f.opens.length, 2)
  })
}

test('GUI kind mismatch refuses the projection', async t => {
  const f = fixture(t)
  await f.socket.onopen()
  await f.project(f.opens[0], '[]', { kind: 'world' })
  assert.equal(f.values.length, 0)
  assert.match(f.errors[0], /kind/)
})
