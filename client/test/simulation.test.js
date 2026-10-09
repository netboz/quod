import { strict as assert } from 'node:assert'
import { test } from 'node:test'
import { NullEngine } from '@babylonjs/core/Engines/nullEngine.js'
import { Scene } from '@babylonjs/core/scene.js'
import { simulationProjection, advanceSimulation, connectSimulation, readSimulationWorld } from '../src/simulation.js'
import { driveInput, snapInput, pushInput } from '../src/locomotion.js'
import { paintMarks, paintBodyPoses } from '../src/scene.js'

const anchor = 'a'.repeat(32)
const mark = (body = '10', revision = '2', colour = '#FFFFFF', id = 'door') =>
  `mark(<<"${id}">>,<<"box">>,[f(<<"width">>,2000),f(<<"height">>,2000),f(<<"depth">>,200)],` +
  `body_pose(${body},${revision}),surface(<<"${colour}">>,0,900,0,[]),unlabelled,` +
  `depicts(<<"room">>,<<"${anchor}">>,door(${body})))`
const sample = (changes = {}) => ({ schema: 1, units: 'metres_seconds', space: 'world',
  world: 'room', authority: 'actor', epoch: '1', generation: '1', incarnation: 'token',
  structure: '2', tick: '1', poses: [{ body: '10', revision: '2', position: [0, 1, 0], rotation: [0, 0, 0, 1] }], ...changes })
const projection = (frame = sample(), marks = `[${mark()}]`, view = 'read1') =>
  simulationProjection({ type: 'projection', expires_ms: String(Date.now() + 30000), frame, marks, view, height: '4' })
const motion = (frame, view = 'read1') => ({ type: 'simulation_frame', frame, view })

test('dropped ticks are latest-wins; late, duplicate, foreign and old-incarnation frames cannot move the view', () => {
  const first = projection()
  const moved = advanceSimulation(first, motion(sample({ tick: '150', poses: [
    { body: '10', revision: '2', position: [2, 1, 3], rotation: [0, 0.6, 0, 0.8] },
  ] })))
  assert.equal(moved.tick, 150n)
  for (const change of [{ tick: '149' }, { tick: '150' }, { epoch: '2', tick: '200' },
    { generation: '2', tick: '200' }, { incarnation: 'other', tick: '200' },
    { structure: '3', tick: '200' }, { world: 'another', tick: '200' }, { authority: 'other', tick: '200' }]) {
    assert.equal(advanceSimulation(moved, motion(sample(change))), moved)
  }
  assert.equal(advanceSimulation(moved, motion(sample({ tick: '200' }), 'old-read')), moved)
})

test('appearance refresh retains the live transform; deletion/recreation reusing a mark cannot inherit the old pose', () => {
  const engine = new NullEngine(), scene = new Scene(engine)
  try {
    let current = projection(sample({ tick: '100', poses: [
      { body: '10', revision: '2', position: [3, 2, 1], rotation: [0, 0.6, 0, 0.8] },
    ] }))
    let painted = paintMarks(scene, current.marks)
    paintBodyPoses(painted, current.poses)
    const door = painted.get('door').node
    const quaternion = door.rotationQuaternion.asArray()
    current = projection(sample({ tick: '101', poses: [...current.poses.values()] }), `[${mark('10', '2', '#123456')}]`, 'refresh')
    painted = paintMarks(scene, current.marks, painted)
    assert.equal(painted.get('door').node, door)
    assert.deepEqual(door.position.asArray(), [3, 2, 1])
    assert.deepEqual(door.rotationQuaternion.asArray(), quaternion)
    paintBodyPoses(painted, current.poses)
    painted = paintMarks(scene, [], painted)
    assert.equal(door.isDisposed(), true)
    const replacement = projection(sample({ structure: '4', tick: '105', poses: [
      { body: '12', revision: '4', position: [9, 2, 1], rotation: [0, 0, 0, 1] },
    ] }), `[${mark('12', '4')}]`, 'replacement')
    painted = paintMarks(scene, replacement.marks, painted)
    assert.equal(painted.get('door').node.isEnabled(), false)
    paintBodyPoses(painted, current.poses)
    assert.equal(painted.get('door').node.isEnabled(), false)
    paintBodyPoses(painted, replacement.poses)
    assert.deepEqual(painted.get('door').node.position.asArray(), [9, 2, 1])
    assert.equal(advanceSimulation(replacement, motion(sample({ tick: '900' }), 'refresh')), replacement)
  } finally { scene.dispose(); engine.dispose() }
})

test('restart, authority change and reconnect begin with a fresh current projection', () => {
  const old = projection(sample({ tick: '900' }))
  for (const changes of [{ generation: '2', incarnation: 'new' },
    { authority: 'next-actor', epoch: '2', generation: '3', incarnation: 'new' }, {}]) {
    const restored = projection(sample({ ...changes, tick: '1' }), undefined, 'new-read')
    assert.equal(restored.tick, 1n)
    assert.equal(advanceSimulation(restored, motion(sample({ tick: '901' }), old.view)), restored)
  }
})

test('uint64 identities remain exact; a body projection has one complete pose source', () => {
  const id = '18446744073709551615'
  const large = projection(sample({ poses: [{ body: id, revision: '2', position: [1, 2, 3], rotation: [0, 0, 0, 1] }] }), `[${mark(id)}]`)
  assert.equal(large.marks[0].body.id, id)
  assert.throws(() => projection(sample(), `[${mark('11')}]`), /projection/)
  assert.throws(() => projection(sample({ poses: [] })), /projection/)
  assert.throws(() => projection(sample({ poses: [sample().poses[0], sample().poses[0]] })), /body pose/)
  assert.throws(() => advanceSimulation(large, motion(sample({ tick: '2' }))), /body set/)
})

test('socket refresh and reconnect sign fresh reads and reject delayed messages from a previous view', async () => {
  let socket
  const identity = { networkId: new Uint8Array(32), provider: {
    publicKey: new Uint8Array(32), sign: async () => new Uint8Array(64),
  }, session: { session_id: 'session', expires_ms: Date.now() + 600000 } }
  const agent = { namespace: 'room', anchor: new Uint8Array(32), instanceText: 'viewer.' }
  const projections = [], frames = [], statuses = [], refreshes = []
  class Socket {
    constructor() { socket = this; this.sent = []; this.waiters = [] }
    send(json) {
      const message = JSON.parse(json)
      const waiter = this.waiters.shift()
      if (waiter) waiter(message)
      else this.sent.push(message)
    }
    next() { return this.sent.length ? Promise.resolve(this.sent.shift()) : new Promise(resolve => this.waiters.push(resolve)) }
    receive(message) { this.onmessage({ data: JSON.stringify(message) }) }
    close() { this.onclose?.() }
  }
  const connect = () => connectSimulation(identity, agent, {
    projection: current => projections.push(current), frame: current => frames.push(current),
    unavailable: reason => statuses.push(reason),
    refreshing: () => refreshes.push(true),
  }, { WebSocket: Socket, url: 'ws://localhost/api/simulation' })
  const viewId = async request => Buffer.from(await crypto.subtle.digest('SHA-256',
    Buffer.from(request.request, 'base64url'))).toString('base64url')
  let stream = connect()
  socket.onopen()
  const open = await socket.next(), first = await viewId(open)
  socket.receive({ type: 'projection', expires_ms: String(Date.now() + 30000), view: first, height: '4', marks: `[${mark()}]`, frame: sample() })
  assert.deepEqual(await socket.next(), { type: 'ack', view: first, tick: '1' })
  socket.receive({ type: 'refresh', reason: 'durable_gap' })
  assert.equal(refreshes.length, 1)
  assert.equal(statuses.length, 0, 'refresh must keep the painted pose visible')
  const refresh = await socket.next(), second = await viewId(refresh)
  assert.notEqual(open.request, refresh.request)
  socket.receive(motion(sample({ tick: '900' }), first))
  assert.equal(frames.length, 0)
  socket.receive({ type: 'projection', expires_ms: String(Date.now() + 30000), view: second, height: '5', marks: `[${mark()}]`, frame: sample({ tick: '5' }) })
  assert.equal((await socket.next()).view, second)
  socket.receive(motion(sample({ tick: '12' }), second))
  assert.equal((await socket.next()).tick, '12')
  assert.equal(frames.at(-1).tick, 12n)
  stream.close()
  stream = connect()
  socket.onopen()
  const reconnect = await socket.next(), third = await viewId(reconnect)
  assert.notEqual(third, second)
  socket.receive({ type: 'projection', expires_ms: String(Date.now() + 30000), view: second, height: '5', marks: `[${mark()}]`, frame: sample() })
  assert.equal(projections.length, 2)
  socket.receive({ type: 'projection', expires_ms: String(Date.now() + 30000), view: third, height: '6', marks: `[${mark()}]`, frame: sample({ generation: '2', incarnation: 'new' }) })
  assert.equal((await socket.next()).view, third)
  assert.equal(projections.length, 3)
  stream.close()
  // A retired view's asynchronous signer cannot hide its successor's scene.
  let rejectSign
  identity.provider.sign = () => new Promise((_, reject) => { rejectSign = reject })
  stream = connect()
  const signing = socket.onopen()
  stream.close()
  const before = statuses.length
  rejectSign(new Error('late retired signer failure'))
  await signing
  assert.equal(statuses.length, before)
})

test('the signers ontology selects an exact foreign world without changing the acting agent', async () => {
  const identity = { networkId: new Uint8Array(32), provider: {
    publicKey: new Uint8Array(32), sign: async () => new Uint8Array(64),
  }, session: { session_id: 'session', expires_ms: Date.now() + 60000 } }
  const agent = { namespace: 'human', anchor: new Uint8Array(32), instanceText: 'human.' }
  const seen = []
  const world = await readSimulationWorld(identity, agent, { post: async (url, body) => {
    seen.push({ url, request: Buffer.from(body.request, 'base64url').toString() })
    return { result: 'ok', bindings: [{ World: `ontology_ref(<<"room">>,<<"${anchor}">>)` }] }
  } })
  assert.equal(world.namespace, 'room')
  assert.equal(world.anchor.length, 32)
  assert.equal(seen[0].url, '/api/goals/read')
  assert.ok(seen[0].request.includes('physics_client_world(World).'))
  assert.ok(seen[0].request.includes('human.'))
})

for (const [kind, input] of [['snap', snapInput(785)], ['push', pushInput('18446744073709551615', '2', [1, 0, 0])]]) {
test(`${kind} admission waits for its discrete outcome and stops after uncertain loss`, async () => {
  let socket, settle
  const posts = [], statuses = [], refusals = []
  const identity = { networkId: new Uint8Array(32), provider: {
    publicKey: new Uint8Array(32), sign: async () => new Uint8Array(64),
  }, session: { session_id: 'session', expires_ms: Date.now() + 60000 } }
  const agent = { namespace: 'human', anchor: new Uint8Array(32), instanceText: 'human.' }
  class Socket {
    constructor() { socket = this; this.sent = [] }
    send(text) { this.sent.push(JSON.parse(text)) }
    close() { this.onclose?.() }
    receive(message) { this.onmessage({ data: JSON.stringify(message) }) }
  }
  const connect = () => connectSimulation(identity, agent, { projection() {}, frame() {},
    unavailable: s => statuses.push(s), refused: s => refusals.push(s) }, {
    WebSocket: Socket, url: 'ws://localhost/api/simulation', world: { namespace: 'room', anchor: new Uint8Array(32) },
    post: (url, body) => { posts.push({ url, body }); return new Promise((resolve, reject) => { settle = { resolve, reject } }) },
  })
  const stream = connect()
  let recovered
  try {
    await socket.onopen()
    const open = socket.sent[0]
    assert.equal(open.world_namespace, 'room')
    const view = Buffer.from(await crypto.subtle.digest('SHA-256', Buffer.from(open.request, 'base64url'))).toString('base64url')
    const frame = sample({ world: `world_ref(<<"room">>,<<"${anchor}">>,room)`,
      authority: `agent_instance_ref(<<"room">>,<<"${anchor}">>,actor)`,
      incarnation: Buffer.alloc(32).toString('base64url'), registration: Buffer.alloc(32, 1).toString('base64url'),
      control_state: { sequence: '7', pending: false, result: 'idle' } })
    socket.receive({ type: 'projection', expires_ms: String(Date.now() + 30000), height: '5', marks: `[${mark()}]`, view, frame,
      control: 'control(human,2,controlled_agent(vehicle,1,10,2,motion(free,2000,1600,500,query_limits(2,0,8,128),[snap(785)]),viewpoint(eye,pose(vector(0,0,0),rotation(0,0,0)),view_only)))' })
    const first = stream.command(input)
    await Promise.resolve()
    assert.equal(await stream.command(driveInput([0, 0, 0])), false)
    assert.equal(posts.length, 1)
    assert.equal(posts[0].url, '/api/goals/control')
    const request = Buffer.from(posts[0].body.request, 'base64url').toString()
    assert.ok(request.includes('control_frame'))
    if (kind === 'push') assert.ok(request.includes('push(body(18446744073709551615,2),vector(1000,0,0))'))
    settle.resolve({ result: 'ok' }); assert.equal(await first, true)
    assert.equal(await stream.command(driveInput([0, 0, 0])), false, 'queued discrete input must not be overwritten')
    socket.receive(motion({ ...frame, tick: '2', control_state: { sequence: '8', pending: false, result: 'clear' } }, view))
    const next = stream.command(driveInput([0, 0, 0]))
    await Promise.resolve()
    settle.reject(new Error('lost response'))
    assert.equal(await next, false)
    assert.equal(posts.length, 2)
    assert.equal(await stream.command(driveInput([1, 0, 0])), false)
    assert.equal(posts.length, 2)
    assert.deepEqual(statuses, ['lost response'])
    stream.close()
    recovered = connect()
    await socket.onopen()
    const fresh = socket.sent[0]
    const freshView = Buffer.from(await crypto.subtle.digest('SHA-256', Buffer.from(fresh.request, 'base64url'))).toString('base64url')
    socket.receive({ type: 'projection', expires_ms: String(Date.now() + 30000), height: '5', marks: `[${mark()}]`, view: freshView,
      frame: { ...frame, registration: Buffer.alloc(32, 2).toString('base64url'),
        control_state: { sequence: '9', pending: false, result: 'suspended' } },
      control: 'control(human,2,controlled_agent(vehicle,1,10,2,motion(free,2000,1600,500,query_limits(2,0,8,128),[snap(785)]),viewpoint(eye,pose(vector(0,0,0),rotation(0,0,0)),view_only)))' })
    assert.equal(posts.length, 2, 'a fresh projection does not replay the uncertain command')
    const resumed = recovered.command(input)
    await Promise.resolve()
    assert.equal(posts.length, 3)
    assert.notEqual(posts[2].body.request, posts[1].body.request)
    assert.match(Buffer.from(posts[2].body.request, 'base64url').toString(), /,2,10,(?:snap|push)\(/)
    settle.resolve({ result: 'ok' })
    assert.equal(await resumed, true)
    socket.receive(motion({ ...frame, tick: '2', registration: Buffer.alloc(32, 2).toString('base64url'),
      control_state: { sequence: '10', pending: false, result: 'clear' } }, freshView))
    const refused = recovered.command(input)
    await Promise.resolve()
    settle.resolve({ result: 'fail' })
    assert.equal(await refused, false)
    assert.deepEqual(statuses, ['lost response'], 'a definite proof refusal keeps the current view available')
    assert.deepEqual(refusals, ['Movement was refused.'])
    const following = recovered.command(input)
    await Promise.resolve()
    assert.equal(posts.length, 5, 'a refused discrete command does not wait for feedback that cannot arrive')
    assert.match(Buffer.from(posts[4].body.request, 'base64url').toString(), /,2,12,(?:snap|push)\(/)
    settle.resolve({ result: 'ok' })
    assert.equal(await following, true)
  } finally { stream.close(); recovered?.close() }
})
}
