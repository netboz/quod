import { strict as assert } from 'node:assert'
import { test } from 'node:test'
import { readFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { NullEngine } from '@babylonjs/core/Engines/nullEngine.js'
import { Scene } from '@babylonjs/core/scene.js'
import { connectWorldView } from '../src/simulation.js'
import { atom } from '../src/prolog-term.js'
import { paintMarks, paintBodyPoses, paintTerrain, clearMarks } from '../src/scene.js'
import { createRenderResources } from '../src/render-resources.js'

const payload = new Uint8Array(readFileSync(new URL('./fixtures/voxel-plane.qvt', import.meta.url)))
const digest = createHash('sha256').update(payload).digest('hex')
const terrain = 'mark(<<"land">>,<<"terrain">>,terrain_geometry(<<"qvt1">>,[material(9,surface(<<"#447722">>,0,900,0,[]))],view_distance(4000,1000,2000),resources(10000,40000,1000,1000,2)),body_pose(0,1),terrain_surfaces,unlabelled,depicts(<<"room">>,<<"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">>,land))'
const frame = { schema: 2, units: 'metres_seconds', space: 'local', origin_mm: ['0', '0', '0'], origin_seq: '0', world: 'room', authority: 'actor',
  epoch: '1', generation: '1', incarnation: 'token', structure: '1', tick: '1',
  poses: [{ body: '0', revision: '1', position: [0, 0, 0], rotation: [0, 0, 0, 1] }] }
const row = { index: 0, body: '0', revision: '1', chunk: ['0', '0', '0'], origin_mm: ['0', '0', '0'],
  spacing_mm: 500, digest, costs: [4880, 13824, 384, 128, 1] }

async function connection(render, failures, physical = frame) {
  let socket
  class Socket {
    constructor() { socket = this; this.sent = []; this.waiters = [] }
    send(json) { const value = JSON.parse(json); const waiter = this.waiters.shift(); if (waiter) waiter(value); else this.sent.push(value) }
    next() { return this.sent.length ? Promise.resolve(this.sent.shift()) : new Promise(resolve => this.waiters.push(resolve)) }
    receive(message) { this.onmessage({ data: JSON.stringify(message) }) }
    close() { this.onclose?.() }
  }
  const identity = { networkId: new Uint8Array(32), provider: {
    publicKey: new Uint8Array(32), sign: async () => new Uint8Array(64),
  }, session: { session_id: 'session', expires_ms: Date.now() + 600000 } }
  const stream = connectWorldView(identity, { namespace: 'room', anchor: new Uint8Array(32), instanceText: 'viewer.' }, {
    projection: render, frame: render, unavailable: text => failures.push(text), refreshing: () => {},
  }, { WebSocket: Socket, url: 'ws://localhost/api/views', world: {
    namespace: 'room', anchor: new Uint8Array(32), instance: atom('room'),
  }, mode: 'playing', dependencies: [] })
  socket.onopen()
  const open = await socket.next()
  const view = createHash('sha256').update(Buffer.from(open.request, 'base64url')).digest('base64url')
  socket.receive({ type: 'projection', selection: 'active', view, height: '1',
    expires_ms: String(Date.now() + 30000), marks: `[${terrain}]`, frame: physical })
  assert.equal((await socket.next()).type, 'ack')
  return { stream, socket, view }
}

test('signed terrain stream waits for rendering, retains unchanged chunks and evicts before replacement', async () => {
  const engine = new NullEngine(), scene = new Scene(engine), resources = createRenderResources(scene)
  let painted = new Map(), current, hold = null, rendered, signal
  const failures = []
  const render = view => {
    current = view
    painted = paintMarks(scene, view.marks, painted, resources)
    paintBodyPoses(painted, view.poses)
    return paintTerrain(scene, painted, view, resources).then(async () => { signal?.(); await hold })
  }
  const { socket, stream, view } = await connection(render, failures)
  const token = Buffer.alloc(32, 1).toString('base64url')
  try {
    assert.equal(painted.get('land').node.isEnabled(), false)
    socket.receive({ type: 'terrain_manifest', interest_seq: '0', view, token, chunks: [row] })
    assert.deepEqual((await socket.next()).want, [0])
    let release
    hold = new Promise(resolve => { release = resolve })
    rendered = new Promise(resolve => { signal = resolve })
    socket.receive({ type: 'terrain_chunk', view, token, index: 0, payload: Buffer.from(payload).toString('base64url') })
    await rendered
    assert.equal(socket.sent.length, 0, 'renderer completion holds delivery credit')
    const chunk = painted.get('land').chunks.get('0:0,0,0'), instance = chunk.instance
    assert.ok(instance.rootNodes.length > 0)
    assert.equal(painted.get('land').node.isEnabled(), false)
    release(); hold = null; signal = null
    assert.equal((await socket.next()).chunk, 0)
    socket.receive({ type: 'terrain_complete', view, token })
    assert.equal((await socket.next()).complete, true)
    assert.equal(current.terrainReady, true)
    assert.equal(painted.get('land').node.isEnabled(), true)
    const nextToken = Buffer.alloc(32, 2).toString('base64url')
    socket.receive({ type: 'simulation_frame', view, frame: { ...frame, tick: '2' } })
    assert.equal((await socket.next()).tick, '2')
    socket.receive({ type: 'terrain_manifest', interest_seq: '0', view, token: nextToken, chunks: [row] })
    assert.deepEqual((await socket.next()).want, [])
    assert.equal(painted.get('land').chunks.get('0:0,0,0').instance, instance)
    socket.receive({ type: 'terrain_complete', view, token: nextToken })
    await socket.next()
    socket.receive({ type: 'terrain_manifest', interest_seq: '0', view, token, chunks: [] })
    assert.deepEqual((await socket.next()).want, [])
    assert.equal(painted.get('land').chunks.size, 0)
    assert.equal(chunk.node.isDisposed(), true)
    assert.deepEqual(failures, [])
  } finally { stream.close(); clearMarks(painted); resources.dispose(); scene.dispose(); engine.dispose() }
})

test('an unauthorized aggregate is rejected before bytes or renderer allocations', async () => {
  const failures = [], rendered = []
  const { socket, stream, view } = await connection(view => rendered.push(view), failures)
  try {
    socket.receive({ type: 'terrain_manifest', interest_seq: '0', view, token: Buffer.alloc(32).toString('base64url'),
      chunks: Array.from({ length: 3 }, (_, index) => ({ ...row, index,
        chunk: [String(index), '0', '0'], origin_mm: [String(index * 4000), '0', '0'] })) })
    // The asynchronous handler rejects before its first resource await.
    await Promise.resolve(); await Promise.resolve()
    assert.match(failures[0], /aggregate allowance/)
    assert.equal(rendered.length, 1)
    assert.equal(socket.sent.length, 0)
  } finally { stream.close() }
})

test('a body revision keeps unchanged models dormant until its new signed manifest confirms them', { timeout: 5000 }, async () => {
  const engine = new NullEngine(), scene = new Scene(engine), resources = createRenderResources(scene)
  let painted = new Map(), current
  const failures = []
  const render = value => {
    current = value
    painted = paintMarks(scene, value.marks, painted, resources)
    paintBodyPoses(painted, value.poses)
    return paintTerrain(scene, painted, value, resources)
  }
  const { socket, stream, view } = await connection(render, failures)
  const token = Buffer.alloc(32, 6).toString('base64url')
  try {
    socket.receive({ type: 'terrain_manifest', view, token, interest_seq: '0', chunks: [row] })
    await socket.next()
    socket.receive({ type: 'terrain_chunk', view, token, index: 0, payload: Buffer.from(payload).toString('base64url') })
    await socket.next()
    socket.receive({ type: 'terrain_complete', view, token }); await socket.next()
    const model = painted.get('land').chunks.get('0:0,0,0').instance
    socket.receive({ type: 'refresh', reason: 'changed' })
    const open = await socket.next()
    const next = createHash('sha256').update(Buffer.from(open.request, 'base64url')).digest('base64url')
    socket.receive({ type: 'projection', selection: 'active', view: next, height: '2',
      expires_ms: String(Date.now() + 30000), marks: `[${terrain.replace('body_pose(0,1)', 'body_pose(0,2)')}]`,
      frame: { ...frame, structure: '2', poses: [{ ...frame.poses[0], revision: '2' }] } })
    await socket.next()
    assert.equal(current.terrain, null)
    assert.equal(painted.get('land').node.isEnabled(), false)
    assert.equal(painted.get('land').chunks.get('0:0,0,0').instance, model)
    socket.receive({ type: 'terrain_manifest', view: next, token, interest_seq: '0', chunks: [{ ...row, revision: '2' }] })
    assert.deepEqual((await socket.next()).want, [])
    socket.receive({ type: 'terrain_complete', view: next, token }); await socket.next()
    assert.equal(painted.get('land').chunks.get('0:0,0,0').instance, model)
    assert.equal(painted.get('land').node.isEnabled(), true)
    assert.deepEqual(failures, [])
  } finally { stream.close(); clearMarks(painted); resources.dispose(); scene.dispose(); engine.dispose() }
})

test('camera interest is canonical, boundary driven, and stale completion cannot open the new horizon', { timeout: 5000 }, async () => {
  let current
  const failures = [], huge = 2n ** 100n * 4000n
  const { socket, stream, view } = await connection(value => { current = value }, failures,
    { ...frame, origin_mm: [String(huge), '0', '0'] })
  const token = Buffer.alloc(32, 7).toString('base64url')
  const placed = { ...row, chunk: [String(2n ** 100n), '0', '0'], origin_mm: [String(huge), '0', '0'] }
  try {
    assert.equal(current.interest([2, 2, 2]), true)
    assert.deepEqual(await socket.next(), { type: 'terrain_interest', view, sequence: '1',
      centre_mm: [String(huge + 2000n), '2000', '2000'] })
    assert.equal(current.interest([2.5, 2, 2]), false)
    assert.equal(current.terrainReady, false)
    socket.receive({ type: 'terrain_manifest', view, token, interest_seq: '0', chunks: [placed] })
    assert.deepEqual((await socket.next()).want, [])
    socket.receive({ type: 'terrain_complete', view, token })
    assert.equal((await socket.next()).complete, true)
    assert.equal(current.terrainReady, false)
    socket.receive({ type: 'terrain_manifest', view, token, interest_seq: '1', chunks: [placed] })
    assert.deepEqual((await socket.next()).want, [0])
    socket.receive({ type: 'terrain_chunk', view, token, index: 0, payload: Buffer.from(payload).toString('base64url') })
    assert.equal((await socket.next()).chunk, 0)
    socket.receive({ type: 'terrain_complete', view, token })
    assert.equal((await socket.next()).complete, true)
    assert.equal(current.terrainReady, true)
    assert.equal(current.interest([3.2, 2, 2]), true)
    assert.equal((await socket.next()).sequence, '2')
    assert.equal(current.terrainReady, false)
    socket.receive({ type: 'simulation_frame', view, frame: { ...frame, tick: '2', origin_seq: '1',
      origin_mm: [String(huge + 4000n), '0', '0'] } })
    assert.equal((await socket.next()).type, 'ack')
    assert.equal(current.interest([-0.8, 2, 2]), false, 'a local rebase does not change canonical camera interest')
    assert.equal(socket.sent.length, 0)
    assert.deepEqual(failures, [])
  } finally { stream.close() }
})


test('camera movement during checksum verification releases credit without installing an old chunk', { timeout: 5000 }, async t => {
  let current
  const failures = []
  const { socket, stream, view } = await connection(value => { current = value }, failures)
  const token = Buffer.alloc(32, 8).toString('base64url')
  const original = crypto.subtle.digest.bind(crypto.subtle)
  let entered, release
  const checking = new Promise(resolve => { entered = resolve })
  const hold = new Promise(resolve => { release = resolve })
  t.mock.method(crypto.subtle, 'digest', async (...args) => {
    entered(); await hold; return original(...args)
  })
  try {
    current.interest([0, 0, 0]); await socket.next()
    socket.receive({ type: 'terrain_manifest', view, token, interest_seq: '1', chunks: [row] })
    assert.deepEqual((await socket.next()).want, [0])
    socket.receive({ type: 'terrain_chunk', view, token, index: 0, payload: Buffer.from(payload).toString('base64url') })
    await checking
    current.interest([2, 0, 0]); assert.equal((await socket.next()).sequence, '2')
    release()
    assert.equal((await socket.next()).chunk, 0)
    assert.equal(current.terrain.size, 0)
    socket.receive({ type: 'terrain_complete', view, token })
    assert.equal((await socket.next()).complete, true)
    assert.equal(current.terrainReady, false)
    assert.deepEqual(failures, [])
  } finally { release(); stream.close() }
})

test('large canonical terrain keeps the same model across a local frame shift', async () => {
  const engine = new NullEngine(), scene = new Scene(engine), resources = createRenderResources(scene)
  const chunkX = 2n ** 100n, origin = chunkX * 4000n
  let painted = new Map()
  const render = view => {
    painted = paintMarks(scene, view.marks, painted, resources)
    paintBodyPoses(painted, view.poses)
    return paintTerrain(scene, painted, view, resources)
  }
  const failures = [], physical = { ...frame, origin_mm: [String(origin), '0', '0'] }
  const { socket, stream, view } = await connection(render, failures, physical)
  const token = Buffer.alloc(32, 1).toString('base64url')
  try {
    socket.receive({ type: 'terrain_manifest', interest_seq: '0', view, token, chunks: [{ ...row,
      chunk: [String(chunkX), '0', '0'], origin_mm: [String(origin), '0', '0'] }] })
    assert.deepEqual((await socket.next()).want, [0])
    socket.receive({ type: 'terrain_chunk', view, token, index: 0, payload: Buffer.from(payload).toString('base64url') })
    await socket.next()
    socket.receive({ type: 'terrain_complete', view, token }); await socket.next()
    const entry = painted.get('land').chunks.get(`0:${chunkX},0,0`), model = entry.instance
    assert.deepEqual(entry.node.position.asArray(), [0, 0, 0])
    socket.receive({ type: 'simulation_frame', view, frame: { ...physical, tick: '2', origin_seq: '1',
      origin_mm: [String(origin + 4000n), '0', '0'] } })
    await socket.next()
    assert.equal(entry.instance, model)
    assert.deepEqual(entry.node.position.asArray(), [-4, 0, 0])
    assert.deepEqual(failures, [])
  } finally { stream.close(); clearMarks(painted); resources.dispose(); scene.dispose(); engine.dispose() }
})
