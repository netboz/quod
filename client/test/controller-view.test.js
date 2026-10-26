import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { readControllerView, connectControllerView } from '../src/controller-view.js'
import { validateGlb } from '../src/glb-profile.js'
const hash = 'bd201855c8114b9b0e9cdd465d6f08413d18604894c839fb78d54d890c2adc94'
const value = `controller_view(0,<<"${'d'.repeat(32)}">>,mapping(1,[role(navigation,hand(left)),role(menu,hand(right))],
 [bind(select,any,trigger,press_release,local(select)),bind(menu,menu,pad,radial(240),local(menu)),bind(teleport,navigation,pad,sector(forward,500,grip),control(teleport(500)))],
 [profile(htc_vive_controller,controller([<<"htc-vive">>],[component(trigger,<<"xr-standard-trigger">>,trigger,[press,value]),component(grip,<<"xr-standard-squeeze">>,squeeze,[press]),component(pad,<<"xr-standard-touchpad">>,touchpad,[press,touch,axes2])],
 [target_ray,grip],tracked_model(grip,asset(<<"${hash}">>,<<"gltf2-static-v1">>,bounds(-59,-70,-117,59,23,106),resources(1114152,665696,17551,17344,37,1,4194304)))))]))`

test('Vive description uses the exact packaged model, admitted by the existing GLB validator', () => {
  const decoded = readControllerView(value)
  assert.deepEqual(decoded.roles, { navigation: 'left', menu: 'right' })
  assert.equal(decoded.bindings[2].fraction, .5)
  const model = decoded.profiles[0].model
  const data = readFileSync(new URL(`../../ui/public/assets/models/${hash}.glb`, import.meta.url))
  assert.equal(createHash('sha256').update(data).digest('hex'), hash)
  const admitted = validateGlb(data, model.allowed)
  assert.deepEqual(admitted.boundsMm, model.bounds)
  for (const broken of [value.replace('mapping(1,', 'mapping(2,'), value.replace('hand(left)', 'hand(unknown)'),
    value.replace('radial(240)', 'radial(0)'), value.replace('local(select)', 'local(run_code)')]) {
    assert.throws(() => readControllerView(broken))
  }
  assert.throws(() => readControllerView(value.replace('bind(menu,menu,pad,radial(240),local(menu))',
    'bind(drive,any,pad,axes_while(grip),control(drive))')))
})

test('preferences reuse signed-view renewal, ignore old replies and stop at expiry with no write', async t => {
  t.mock.timers.enable({ apis: ['setTimeout', 'Date'], now: 1800000000000 })
  let socket, notifyOpen
  const values = [], discards = [], errors = [], opens = []
  class Socket {
    constructor() { socket = this }
    send(data) { const message = JSON.parse(data); assert.equal(message.type, 'open'); opens.push(message); notifyOpen?.(); notifyOpen = null }
    close() {}
    project(open, overrides = {}) { this.onmessage({ data: JSON.stringify({ type: 'projection', kind: 'controller_preferences', view: createHash('sha256').update(Buffer.from(open.request, 'base64url')).digest('base64url'),
      height: '1', expires_ms: String(Date.now() + 30000), value, ...overrides }) }) }
  }
  const identity = { networkId: new Uint8Array(32), provider: { publicKey: new Uint8Array(32), sign: async () => new Uint8Array(64) },
    session: { session_id: 'session', expires_ms: Date.now() + 600000 } }
  const human = { namespace: 'human', anchor: Buffer.alloc(32).toString('base64url'), instanceText: 'me.' }
  const stream = connectControllerView(identity, human, { projection: m => values.push(m), discard: () => discards.push(true), unavailable: e => errors.push(e) },
    { WebSocket: Socket, url: 'ws://localhost/api/views' })
  t.after(() => stream.close())
  await socket.onopen(); socket.project(opens[0])
  assert.equal(values.length, 1)
  assert.equal(opens[0].view_kind, 'controller_preferences')
  assert.match(Buffer.from(opens[0].request, 'base64url').toString(), /controller_preferences_view\(me,View\)/)
  const renewal = new Promise(resolve => { notifyOpen = resolve })
  t.mock.timers.tick(15000); await renewal; socket.project(opens[1])
  assert.equal(values[1].digest, values[0].digest); assert.equal(discards.length, 0)
  socket.project(opens[0]); assert.equal(values.length, 2)
  const refresh = new Promise(resolve => { notifyOpen = resolve })
  socket.onmessage({ data: JSON.stringify({ type: 'refresh', reason: 'ontology changed' }) })
  assert.equal(discards.length, 1); assert.equal(stream.current, null)
  await refresh
  // A stalled refresh cannot retain the invalidated authority past its old expiry.
  t.mock.timers.tick(30001)
  assert.equal(stream.current, null); assert.equal(values.length, 2)
  socket.project(opens[1]); assert.equal(stream.current, null)
  socket.project(opens[2], { value: `controller_view(7,<<"${'i'.repeat(32)}">>,invalid_settings)` })
  assert.equal(values.length, 3); assert.equal(values[2], null)
  assert.ok(stream.current); assert.equal(errors.length, 0)
  const repaired = new Promise(resolve => { notifyOpen = resolve })
  socket.onmessage({ data: JSON.stringify({ type: 'refresh', reason: 'settings repaired' }) })
  await repaired; socket.project(opens[3])
  assert.equal(values.length, 4); assert.ok(values[3])
  t.mock.timers.tick(30001)
  assert.equal(discards.length, 3); assert.match(errors[0], /expired/)
})
