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
