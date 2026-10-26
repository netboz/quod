import { test } from 'node:test'
import assert from 'node:assert/strict'
import { NullEngine } from '@babylonjs/core/Engines/nullEngine.js'
import { Scene } from '@babylonjs/core/scene.js'
import { FreeCamera } from '@babylonjs/core/Cameras/freeCamera.js'
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js'
import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder.js'
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js'
import { Observable } from '@babylonjs/core/Misc/observable.js'
import { WebXRTrackingState } from '@babylonjs/core/XR/webXRTypes.js'
import { WebXRControllerComponent } from '@babylonjs/core/XR/motionController/webXRControllerComponent.js'
import { PointerEventTypes } from '@babylonjs/core/Events/pointerEvents.js'
import { createControllerScene } from '../src/controller-scene.js'

function setup(t) {
  const saved = globalThis.PointerEvent
  globalThis.PointerEvent = class extends Event { constructor(type, init) { super(type); Object.assign(this, init) } }
  t.after(() => { globalThis.PointerEvent = saved })
  const engine = new NullEngine(), scene = new Scene(engine)
  scene.useRightHandedSystem = true
  new FreeCamera('camera', Vector3.Zero(), scene)
  const target = MeshBuilder.CreatePlane('target', { size: 2, sideOrientation: 2 }, scene)
  target.position.z = -1; target.computeWorldMatrix(true)
  const pointer = new TransformNode('source-ray', scene), grip = new TransformNode('source-grip', scene)
  const component = new WebXRControllerComponent('trigger', 'trigger', 0)
  const controller = { uniqueId: 'temporary-source', pointer, grip,
    inputSource: { handedness: 'left', profiles: ['htc-vive'], targetRaySpace: {}, gripSpace: {} },
    motionController: { getComponent: name => name === 'trigger' ? component : null },
    onMotionControllerInitObservable: new Observable(),
    getWorldPointerRayToRef(ray) { ray.origin.copyFrom(pointer.absolutePosition); ray.direction.set(0, 0, -1); ray.length = 100 } }
  const session = Object.assign(new EventTarget(), { visibilityState: 'visible' })
  const manager = { onXRFrameObservable: new Observable(), onXRSessionInit: new Observable(), onXRSessionEnded: new Observable(), referenceSpace: {}, session }
  const xr = { input: { controllers: [controller], onControllerAddedObservable: new Observable(), onControllerRemovedObservable: new Observable() },
    baseExperience: { sessionManager: manager, camera: { trackingState: WebXRTrackingState.TRACKING } } }
  const container = { instantiateModelsToScene: () => ({ rootNodes: [], dispose() {} }) }
  const counts = { acquire: 0, release: 0 }
  const resources = { acquireModel() { counts.acquire++; return { ready: Promise.resolve(container), release() { counts.release++ } } } }
  let picks = 0
  scene.onPointerObservable.add(() => picks++, PointerEventTypes.POINTERPICK)
  const input = createControllerScene(scene, resources, { axes() {}, snap() {}, teleport() {} }, {
    workspace: () => null, changed() {}, error: e => { throw e },
    menu: { open: () => false, move() {}, cancel() {}, commit() {} },
  })
  const profile = { names: ['htc-vive'], model: { digest: 'test', allowed: [], bounds: [], profile: 'gltf2-static-v1', scale: 1, pivot: [0, 0, 0], front: '-z' },
    components: [{ name: 'trigger', id: 'trigger', type: 'trigger', features: ['press'] }] }
  const mapping = { digest: 'mapping', roles: { navigation: 'left', menu: 'right' }, profiles: [profile], bindings: [
    { id: 'select', role: 'any', component: 'trigger', kind: 'press_release', action: 'select' },
  ] }
  input.install(mapping)
  input.connect(xr)
  const frame = (pressed, tracked = true) => {
    component.update({ buttons: [{ pressed, value: Number(pressed), touched: pressed }], axes: [] })
    manager.onXRFrameObservable.notifyObservers({ getPose: () => tracked ? {} : null })
  }
  t.after(() => { input.dispose(); scene.dispose(); engine.dispose() })
  return { input, frame, controller, manager, scene, mapping, counts, picks: () => picks,
    visibility(state) { session.visibilityState = state; session.dispatchEvent(new Event('visibilitychange')) } }
}

test('scene picking does not click a stale tracked mesh on loss, recovery or disposal while pressed', async t => {
  const { input, frame, controller, picks } = setup(t)
  await Promise.resolve(); frame(false); frame(true); frame(true, false)
  frame(true); frame(false)
  assert.equal(picks(), 0)
  frame(true); frame(false)
  assert.equal(picks(), 1)
  frame(true); input.dispose()
  assert.equal(picks(), 1)
  assert.equal(controller.onMotionControllerInitObservable.hasObservers(), false)
  controller.onMotionControllerInitObservable.notifyObservers(controller.motionController)
  frame(false); frame(true); frame(false)
  assert.equal(picks(), 1)
})

for (const state of ['hidden', 'visible-blurred']) test(`${state} cancels without an XR frame and cannot click on return`, t => {
  const f = setup(t)
  f.frame(false); f.frame(true)
  f.visibility(state)
  assert.equal(f.input.status.sources[0].tracked, false)
  f.visibility('visible'); f.frame(false)
  assert.equal(f.picks(), 0)
  f.frame(true); f.frame(false)
  assert.equal(f.picks(), 1)
  // Old session events are detached; the next session owns visibility.
  const next = Object.assign(new EventTarget(), { visibilityState: 'visible' })
  f.manager.session = next; f.manager.onXRSessionInit.notifyObservers(next)
  f.frame(true); f.visibility('hidden'); f.frame(false)
  assert.equal(f.picks(), 2)
  f.frame(true); f.manager.onXRSessionEnded.notifyObservers()
  f.manager.onXRSessionInit.notifyObservers(next); f.frame(false)
  assert.equal(f.picks(), 2)
})

test('refresh withdraws input but retains the verified appearance until its source leaves', async t => {
  const f = setup(t)
  await Promise.resolve(); f.frame(false); f.frame(true)
  const node = f.scene.getTransformNodeByName('mark:controller:temporary-source')
  assert.equal(node.isEnabled(), true)
  assert.deepEqual(f.counts, { acquire: 1, release: 0 })
  f.input.install(null)
  assert.equal(node.isEnabled(), false)
  f.frame(false); f.frame(true); f.frame(false)
  assert.equal(node.isEnabled(), false)
  assert.equal(f.picks(), 0)
  f.input.install(structuredClone(f.mapping)); f.frame(false)
  assert.equal(node.isEnabled(), true)
  f.input.install({ ...structuredClone(f.mapping), digest: 'changed-bindings' }); f.frame(false)
  assert.deepEqual(f.counts, { acquire: 1, release: 0 })
  assert.equal(f.scene.getTransformNodeByName('mark:controller:temporary-source'), node)
  // A different admitted model description must still reconcile resources.
  const changed = structuredClone(f.mapping); changed.digest = 'changed-model'; changed.profiles[0].model.digest = 'different'
  f.input.install(changed)
  assert.deepEqual(f.counts, { acquire: 2, release: 1 })
  f.input.dispose()
  assert.deepEqual(f.counts, { acquire: 2, release: 2 })
})
