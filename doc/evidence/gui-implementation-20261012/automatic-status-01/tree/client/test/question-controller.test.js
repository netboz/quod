import { strict as assert } from 'node:assert'
import { test } from 'node:test'
import { questionController } from '../src/question-controller.js'
import { memoryOperationJournal } from '../src/operation-journal.js'
import { atom } from '../src/prolog-term.js'

const digest = char => `<<"${char.repeat(32)}">>`
function form({ revision = 'r', token = 'v', state = 'awaiting', field = 'name', value = 'Default' } = {}) {
  const tree = 'component(form,form,[property(label,<<"Settings">>)],[' +
    `component(${field},text_box,[property(label,<<"Name">>)],[]),` +
    'component(save,button,[property(label,<<"Save">>)],[])])'
  return `question_form(form_ref(<<"app">>,${digest('a')},form),` +
    `agent_instance_ref(<<"responder">>,${digest('b')},handler),${digest('r')},${state},` +
    `form_view(${digest(revision)},${tree},${digest(token)},[field(${field},<<"${value}">>)],save))`
}
function fixture(t) {
  let snapshot, socket, nextOpen, reply = { result: 'ok' }, expiry = Date.now() + 30000
  const posts = [], journal = memoryOperationJournal(), controllers = []
  const identity = { networkId: new Uint8Array(32), provider: {
    publicKey: new Uint8Array(32), sign: async () => new Uint8Array(64),
  }, session: { session_id: 'session', expires_ms: Date.now() + 600000 } }
  const agent = { namespace: 'human', anchor: Buffer.alloc(32).toString('base64url'), instanceText: 'human.' }
  const reference = { namespace: 'responder', anchor: new Uint8Array(32), question: atom('question') }
  class Socket {
    constructor() { socket = this; this.sent = [] }
    send(json) { this.sent.push(JSON.parse(json)); nextOpen?.(); nextOpen = null }
    close() {}
  }
  const options = { WebSocket: Socket, url: 'ws://localhost/api/views', journal,
    post: async (url, body) => {
      posts.push({ url, body })
      if (reply instanceof Error) throw reply
      return typeof reply === 'function' ? reply(url, body) : reply
    } }
  t.after(() => controllers.forEach(controller => controller.close()))
  return { options, posts, journal, setReply(value) { reply = value }, get state() { return snapshot },
    get socket() { return socket },
    async open(deferOpen = false) {
      const controller = questionController(identity, agent, reference, { ...options, deferOpen })
      controller.subscribe(value => { snapshot = value })
      controllers.push(controller)
      await controller.ready
      if (!deferOpen) await socket.onopen()
      return controller
    },
    async project(value = form()) {
      const open = socket.sent.at(-1)
      const view = Buffer.from(await crypto.subtle.digest('SHA-256', Buffer.from(open.request, 'base64url'))).toString('base64url')
      socket.onmessage({ data: JSON.stringify({ type: 'projection', kind: 'gui_question', view,
        height: '1', expires_ms: String(++expiry), value }) })
    },
    renew: () => socket.onopen(),
    refresh() {
      return new Promise(resolve => {
        nextOpen = resolve
        socket.onmessage({ data: JSON.stringify({ type: 'refresh', reason: 'durable_gap' }) })
      })
    },
  }
}

test('both renderers share one local draft and synchronous submission lock', async t => {
  const f = fixture(t), controller = await f.open()
  assert.equal(f.state.locked, true)
  await f.project()
  controller.edit('name', 'Entered')
  assert.equal(f.state.draft.name, 'Entered')
  let settle, posted
  const sent = new Promise(resolve => { posted = resolve })
  f.setReply(() => new Promise(resolve => { settle = resolve; posted() }))
  const submitting = controller.submit()
  assert.equal(f.state.locked, true)
  await controller.submit(); controller.edit('name', 'Too late')
  await sent
  assert.equal(f.posts.length, 1)
  assert.match(Buffer.from(f.posts[0].body.request, 'base64url').toString(), /gui_submit/)
  assert.equal(f.state.draft.name, 'Entered')
  settle({ result: 'ok' }); await submitting
  assert.equal(f.state.locked, true, 'success cannot make the old awaiting projection editable')
  assert.equal((await f.journal.list()).length, 0)
})

test('unknown submission survives reopening and resolves through outcomes without replay', async t => {
  const f = fixture(t), first = await f.open()
  await f.project()
  f.setReply(Object.assign(new Error('lost response'), { outcomeUnknown: true }))
  await first.submit()
  assert.equal(f.state.pending, 1)
  first.close()
  const second = await f.open(); await f.project()
  await second.submit(); await second.cancel()
  assert.equal(f.posts.length, 1)
  f.setReply({ result: 'operation_outcome', terminal: false, status: 'pending' })
  await second.resolve()
  assert.equal(f.state.pending, 1)
  assert.equal(f.posts[1].url, '/api/goals/outcomes')
  assert.equal(f.posts[1].body.request, f.posts[0].body.request)
  f.setReply({ result: 'operation_outcome', terminal: true, status: 'committed' })
  await second.resolve()
  assert.equal(f.state.pending, 0)
  assert.equal(f.state.locked, true)
  assert.equal(f.posts.filter(post => post.url === '/api/goals/execute').length, 1)
})

test('definite refusal preserves editing; changed schema locks and preserves the previous draft', async t => {
  const f = fixture(t), controller = await f.open()
  await f.project(); controller.edit('name', 'Draft')
  f.setReply({ result: 'fail', reasons: ['policy_changed'] })
  await controller.submit()
  assert.equal(f.state.locked, false)
  assert.equal(f.state.draft.name, 'Draft')
  assert.match(f.state.status, /policy_changed/)
  await f.renew(); await f.project()
  assert.equal(f.state.draft.name, 'Draft', 'unchanged renewal preserves local editing')
  await f.renew(); await f.project(form({ revision: 's', field: 'replacement' }))
  assert.equal(f.state.locked, true)
  assert.equal(f.state.draft.name, 'Draft', 'retired fields keep their entered values')
  assert.equal(f.state.draftView.fields[0].role, 'name', 'old schema still describes the draft')
  assert.equal(f.state.form.view.fields[0].role, 'replacement', 'current authority remains separate')
  assert.equal(f.state.form.interaction, 'stale')
  controller.resetDraft(); controller.edit('name', 'Too late')
  assert.equal(f.state.draft.name, 'Draft')
  await f.renew(); await f.project(form({ revision: 't', field: 'another' }))
  assert.equal(f.state.draftView.fields[0].role, 'name')
  await controller.submit()
  assert.equal(f.posts.length, 1)
})

test('changed defaults preserve input until the human explicitly chooses to replace it', async t => {
  const f = fixture(t), controller = await f.open()
  await f.project(); controller.edit('name', 'Draft')
  await f.renew(); await f.project(form({ token: 'w', value: 'New default' }))
  assert.equal(f.state.locked, false)
  assert.equal(f.state.draft.name, 'Draft')
  assert.equal(f.state.form.values.name, 'New default')
  assert.match(f.state.status, /Defaults changed/)
  assert.equal(f.posts.length, 0)
  controller.resetDraft()
  assert.equal(f.state.draft.name, 'New default')
  assert.equal(f.posts.length, 0, 'choosing defaults is local editing')
  await controller.submit()
  assert.match(Buffer.from(f.posts[0].body.request, 'base64url').toString(), /New default/)
  controller.resetDraft()
  assert.equal(f.state.locked, true, 'reset cannot unlock a completed or uncertain write')
})

test('a question first read stale can become editable only with its accepted schema', async t => {
  const f = fixture(t), controller = await f.open()
  await f.project(form({ revision: 's', field: 'replacement' }))
  assert.equal(f.state.locked, true)
  controller.edit('replacement', 'Cannot edit')
  await f.renew(); await f.project()
  assert.equal(f.state.locked, false)
  assert.deepEqual(f.state.draft, { name: 'Default' })
  assert.equal(f.state.draftView.fields[0].role, 'name')
  controller.edit('name', 'Accepted schema')
  await controller.submit()
  assert.match(Buffer.from(f.posts[0].body.request, 'base64url').toString(), /Accepted schema/)
})

test('a successful submission can be cancelled only after its completion is certified negative', async t => {
  const f = fixture(t), controller = await f.open()
  await f.project(); await controller.submit()
  assert.equal(f.state.canCancel, false)
  await f.renew(); await f.project(form({ state: 'submitted(operation,save,[field(name,<<"Answer">>)])' }))
  f.setReply({ result: 'ok', bindings: [{ Status: 'aborted' }] })
  await controller.check()
  assert.equal(f.state.canCancel, true)
  f.setReply({ result: 'ok' }); await controller.cancel()
  assert.equal(f.state.canCancel, false)
  assert.equal(f.posts.filter(post => post.url === '/api/goals/execute').length, 2)
})

test('only a terminal negative answer permits submitted cancellation', async t => {
  const f = fixture(t), controller = await f.open()
  await f.project(form({ state: 'submitted(operation,save,[field(name,<<"Answer">>)])' }))
  assert.equal(f.state.canCancel, false)
  f.setReply(new Error('outcome unavailable'))
  await controller.check(); await controller.cancel()
  assert.equal(f.state.canCancel, false)
  f.setReply({ result: 'ok', bindings: [{ Status: 'expired' }] })
  await controller.check()
  assert.equal(f.state.canCancel, true)
  f.setReply({ result: 'ok' })
  await controller.cancel()
  assert.match(Buffer.from(f.posts.at(-1).body.request, 'base64url').toString(), /gui_cancel/)
  assert.equal(f.state.canCancel, false)
})

test('unreadable journal cannot authorize a new write', async t => {
  const f = fixture(t)
  f.options.journal = { ...f.journal, list: async () => { throw new Error('storage unavailable') } }
  const controller = await f.open(); await f.project()
  await controller.submit(); await controller.cancel()
  assert.equal(f.state.locked, true)
  assert.equal(f.posts.length, 0)
})

function statusResult(controller) {
  return new Promise(resolve => {
    const detach = controller.subscribe(state => {
      if (/^Answer status[: ]/.test(state.status)) { detach(); resolve(state) }
    })
  })
}

test('reopened submitted questions observe status on view progress without dispatching completion', async t => {
  const f = fixture(t), controller = await f.open()
  const submitted = form({ state: 'submitted(operation,save,[field(name,<<"Answer">>)])' })
  f.setReply(new Error('not yet certified'))
  let observed = statusResult(controller)
  await f.project(submitted)
  assert.equal((await observed).canCancel, false)
  assert.equal(f.posts.length, 1)
  assert.equal(f.posts[0].url, '/api/goals/read')
  assert.match(Buffer.from(f.posts[0].body.request, 'base64url').toString(), /gui_question_status/)
  // A real signed-view refresh, not a retry timer or a manual status button.
  await f.refresh()
  f.setReply({ result: 'ok', bindings: [{ Status: 'expired' }] })
  observed = statusResult(controller)
  await f.project(submitted)
  assert.equal((await observed).canCancel, true)
  assert.equal(f.posts.length, 2)
  assert.equal(f.posts.every(post => post.url === '/api/goals/read'), true)
  assert.equal((await f.journal.list()).length, 0)
  f.setReply({ result: 'ok' })
  await controller.cancel()
  assert.equal(f.posts.filter(post => post.url === '/api/goals/execute').length, 1)
  assert.match(Buffer.from(f.posts.at(-1).body.request, 'base64url').toString(), /gui_cancel/)
})

test('an obsolete status read cannot overwrite the latest projection or authorize cancellation', async t => {
  const f = fixture(t), controller = await f.open()
  f.setReply(new Error('initial status unavailable'))
  const initial = statusResult(controller)
  await f.project(form({ state: 'submitted(operation,save,[field(name,<<"Answer">>)])' }))
  await initial
  let release, dispatched
  const sent = new Promise(resolve => { dispatched = resolve })
  f.setReply(() => new Promise(resolve => { release = resolve; dispatched() }))
  const lateRead = controller.check()
  // Joining the actual transport dispatch avoids timing-based synchronization.
  await sent
  await f.refresh()
  f.setReply(new Error('current status unavailable'))
  const observed = statusResult(controller)
  await f.project(form({ state: 'submitted(operation,save,[field(name,<<"Answer">>)])' }))
  await observed
  release({ result: 'ok', bindings: [{ Status: 'expired' }] })
  await lateRead
  assert.equal(f.state.canCancel, false)
  assert.match(f.state.status, /current status unavailable/)
  assert.equal(f.posts.every(post => post.url === '/api/goals/read'), true)
})

test('a saved uncertain write suppresses automatic status reads until exact resolution', async t => {
  const f = fixture(t), first = await f.open()
  await f.project()
  f.setReply(Object.assign(new Error('lost response'), { outcomeUnknown: true }))
  await first.submit(); first.close()
  const second = await f.open()
  await f.project(form({ state: 'submitted(operation,save,[field(name,<<"Answer">>)])' }))
  assert.equal(f.posts.length, 1)
  assert.equal(f.state.pending, 1)
  f.setReply(url => url === '/api/goals/outcomes'
    ? { result: 'operation_outcome', terminal: true, status: 'committed' }
    : { result: 'ok', bindings: [{ Status: 'aborted' }] })
  const observed = statusResult(second)
  await second.resolve()
  assert.equal((await observed).canCancel, true)
  assert.deepEqual(f.posts.map(post => post.url), ['/api/goals/execute', '/api/goals/outcomes', '/api/goals/read'])
  assert.equal(f.posts[0].body.request, f.posts[1].body.request)
})

test('withdrawn form access does not prevent status-based cancellation of an awaiting question', async t => {
  const f = fixture(t), controller = await f.open()
  assert.equal(f.state.form, null)
  assert.equal(f.state.canCancel, false)
  f.setReply({ result: 'ok', bindings: [{ Status: 'awaiting' }] })
  await controller.check()
  assert.equal(f.state.canCancel, true)
  assert.equal(f.state.locked, true, 'status grants no editing authority')
  f.setReply({ result: 'ok' }); await controller.cancel()
  assert.equal(f.posts.filter(post => post.url === '/api/goals/execute').length, 1)
})


test('prepared controller defers its signed view and shares one draft across mounted consumers', async t => {
  const f = fixture(t), controller = await f.open(true)
  assert.equal(f.socket, undefined)
  assert.equal(controller.started, false)
  assert.equal(controller.current.locked, true)
  assert.equal(f.posts.length, 0)
  let second
  const detach = controller.subscribe(value => { second = value })
  controller.refresh(); await f.renew(); await f.project()
  assert.equal(controller.started, true)
  controller.edit('name', 'One draft')
  assert.equal(second.draft.name, 'One draft')
  detach()
  controller.edit('name', 'Kept while panel is unmounted')
  assert.equal(second.draft.name, 'One draft')
  const detachAgain = controller.subscribe(value => { second = value })
  assert.equal(second.draft.name, 'Kept while panel is unmounted')
  assert.equal(f.posts.length, 0)
  controller.close()
  assert.equal(second.locked, true)
  assert.equal(second.canCancel, false)
  assert.equal(second.status, 'Question view closed.')
  detachAgain()
})
