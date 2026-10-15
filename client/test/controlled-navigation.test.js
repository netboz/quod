import test from 'node:test'
import assert from 'node:assert/strict'
import { NullEngine } from '@babylonjs/core/Engines/nullEngine.js'
import { Scene } from '@babylonjs/core/scene.js'
import { UniversalCamera } from '@babylonjs/core/Cameras/universalCamera.js'
import { Quaternion, Vector3 } from '@babylonjs/core/Maths/math.vector.js'
import '@babylonjs/core/Culling/ray.js'
import { configureDesktopCamera } from '../src/navigation.js'
import { createControlledNavigation } from '../src/controlled-navigation.js'
import { readControl } from '../src/locomotion.js'
import { formatClause } from '../src/prolog-term.js'

const control = (mount = 'pose(vector(1000,200,0),rotation(0,1571,0))') => readControl(
  `control(human,4,controlled_agent(vehicle,2,10,3,motion(grounded(700),2000,1600,500,query_limits(2,0,8,128),[snap(785),teleport(6000,2000,700)]),viewpoint(cockpit,${mount},tracking(view_only,500))))`)

function fixture(run) {
  const engine = new NullEngine(), scene = new Scene(engine)
  scene.useRightHandedSystem = true
  const camera = new UniversalCamera('camera', new Vector3(0, 2, -5), scene)
  configureDesktopCamera(camera)
  const owner = new EventTarget(); owner.defaultView = new EventTarget()
  const sent = [], masks = []
  const navigation = createControlledNavigation(scene, camera, { ownerDocument: owner }, {
    active: () => true, mask: (...value) => masks.push(value),
  })
  const current = { fence: 'first', control: control(), poses: new Map([
    ['10:3', { position: [4, 1, 2], rotation: [0, 0, 0, 1] }],
  ]), feedback: { sequence: '-1', result: 'idle' }, clearance: 0.4,
    command: async input => { sent.push(input); return true } }
  try { run({ scene, camera, owner, navigation, current, sent, masks }) }
  finally { navigation.dispose(); scene.dispose(); engine.dispose() }
}

test('backward desktop travel sends integer zero axes accepted by physics', () => fixture(
  ({ owner, navigation, current, sent }) => {
    current.control = control('pose(vector(0,700,0),rotation(0,0,0))')
    navigation.update(current)
    const event = new Event('keydown'); Object.defineProperty(event, 'key', { value: 's' })
    owner.dispatchEvent(event)
    navigation.render(0)
    assert.equal(sent.length, 1)
    assert.equal(formatClause(sent[0]), 'drive(vector(0, 0, 2000), angular(0, 0, 0)).')
  }))

test('renewing the same binding preserves held travel and authored camera placement', () => fixture(
  ({ camera, owner, navigation, current, sent }) => {
    navigation.update(current)
    const event = new Event('keydown'); Object.defineProperty(event, 'key', { value: 'w' })
    owner.dispatchEvent(event)
    navigation.render(0)
    const placement = camera.parent.position.asArray()
    navigation.update({ ...current, view: 'renewed', expires: Date.now() + 30000,
      physicalFrame: { registration: 'renewed' } })
    navigation.render(250)
    assert.equal(sent.length, 2)
    assert.deepEqual(sent[1], sent[0], 'renewal retains the held direction without another keydown')
    assert.deepEqual(camera.parent.position.asArray(), placement)
    assert.deepEqual(camera.position.asArray(), [0, 0, 0])
  }))

test('authored off-centre cockpit follows accepted body pose; commands cannot translate the camera', () => fixture(
  ({ camera, owner, navigation, current, sent }) => {
    navigation.update(current)
    assert.deepEqual(camera.keysUp, [])
    assert.deepEqual(camera.position.asArray(), [0, 0, 0])
    assert.deepEqual(camera.parent.position.asArray(), [5, 1.2, 2])
    const event = new Event('keydown'); Object.defineProperty(event, 'key', { value: 'w' })
    owner.dispatchEvent(event)
    navigation.render(0)
    assert.equal(sent.length, 1)
    const values = sent[0].args[0].args.map(n => n.value)
    assert.ok(Math.hypot(...values) <= 2000)
    assert.deepEqual(camera.parent.position.asArray(), [5, 1.2, 2])
    current.poses.set('10:3', { position: [4.5, 1, 2], rotation: [0, 0, 0, 1] })
    navigation.update(current)
    assert.deepEqual(camera.parent.position.asArray(), [5.5, 1.2, 2])
    navigation.update(null); navigation.render(600)
    assert.equal(sent.length, 1)
    assert.deepEqual(camera.keysUp, [])
    navigation.update(undefined)
    assert.deepEqual(camera.position.asArray(), [0, 2, -5])
    assert.deepEqual(camera.keysUp, [87, 90, 38])
    camera.position.x += 3
    navigation.update(undefined)
    assert.equal(camera.position.x, 3, 'an observer projection must not reset ongoing travel')
  }))

test('tracked head offsets are calibrated view motion; clearance masks them without moving the body', () => fixture(
  ({ scene, camera, navigation, current, masks }) => {
    const headset = new UniversalCamera('tracked', new Vector3(0.2, 1.8, 0.1), scene)
    headset.rotationQuaternion = Quaternion.Identity()
    navigation.update(current); navigation.xr(headset); navigation.render(0)
    assert.equal(masks.at(-1)[0], false)
    const body = [...current.poses.get('10:3').position]
    headset.position.x += 0.5
    navigation.render(16)
    assert.equal(masks.at(-1)[0], true)
    assert.deepEqual(current.poses.get('10:3').position, body)
    headset.position.x -= 0.5
    navigation.render(32)
    assert.equal(masks.at(-1)[0], false)
    const origin = headset.parent.position.clone()
    headset.position.x += 0.1
    navigation.update(null); navigation.render(40)
    navigation.update(current); navigation.render(41)
    assert.deepEqual(headset.parent.position.asArray(), origin.asArray(), 'view renewal must not recenter tracking')
    camera.position.copyFrom(headset.position)
    navigation.xr(null)
    assert.deepEqual(camera.position.asArray(), [0, 0, 0])
    assert.equal(headset.parent, null)
    navigation.xr(headset)
    navigation.update(null); navigation.render(48)
    assert.equal(masks.at(-1)[0], true)
  }))

test('unknown capabilities and implicit movement profiles fail closed', () => {
  assert.throws(() => readControl('control(human,1,controlled_agent(a,1,2,1,motion(walking),viewpoint(eye,none,view_only)))'))
  assert.equal(readControl('none'), null)
  assert.equal(control().viewpoint.trackingRadius, 0.5)
})

test('Space jumps once and promptly resumes held travel; unavailable control does not jump', () => fixture(
  ({ owner, navigation, current, sent }) => {
    current.control = readControl('control(human,4,controlled_agent(pilot,1,10,3,motion(grounded(900),2500,1600,500,query_limits(2,0,8,128),[jump(4000)]),viewpoint(eye,pose(vector(0,700,0),rotation(0,0,0)),view_only)))')
    navigation.update(current)
    const press = repeat => {
      const event = new Event('keydown', { cancelable: true })
      Object.defineProperties(event, { key: { value: ' ' }, repeat: { value: repeat } })
      owner.dispatchEvent(event)
      return event.defaultPrevented
    }
    const forward = new Event('keydown'); Object.defineProperty(forward, 'key', { value: 'w' })
    owner.dispatchEvent(forward); navigation.render(0)
    assert.equal(press(false), true)
    assert.equal(formatClause(sent[1]), 'jump(4000).')
    navigation.render(1)
    assert.equal(sent.length, 3, 'held travel resumes without waiting for the lease renewal')
    assert.deepEqual(sent[2], sent[0])
    press(true)
    assert.equal(sent.length, 3)
    navigation.update(null); press(false)
    assert.equal(sent.length, 3)
  }))


test('XR entry preserves tracked pitch and roll; free agents cannot request landing teleport', () => fixture(
  ({ scene, navigation, current, sent }) => {
    const headset = new UniversalCamera('tilted', new Vector3(0, 1.8, 0), scene)
    headset.rotationQuaternion = Quaternion.RotationYawPitchRoll(0.7, 0.3, 0.2)
    navigation.update(current); navigation.xr(headset); navigation.render(0)
    const up = Vector3.Up().rotateByQuaternionToRef(headset.parent.rotationQuaternion, new Vector3())
    assert.ok(Vector3.Distance(up, Vector3.Up()) < 1e-6, 'calibration preserves the authored up axis')
    const relative = headset.parent.rotationQuaternion.multiply(headset.rotationQuaternion)
    assert.ok(Math.abs(relative.x) > 0.05, 'tracked pitch survives calibration')
    current.control.grounded = false
    const count = sent.length
    navigation.teleport(Vector3.Forward())
    assert.equal(sent.length, count)
  }))
