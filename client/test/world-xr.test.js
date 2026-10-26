import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { NullEngine } from '@babylonjs/core/Engines/nullEngine.js'
import { Scene } from '@babylonjs/core/scene.js'
import { FreeCamera } from '@babylonjs/core/Cameras/freeCamera.js'
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js'
import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder.js'
import { PointerEventTypes } from '@babylonjs/core/Events/pointerEvents.js'
import { createWorldXR } from '../src/world-xr.js'
import { createControllerScene } from '../src/controller-scene.js'
import { createRenderResources } from '../src/render-resources.js'
import { validateGlb } from '../src/glb-profile.js'

const deferred = () => {
  let resolve, reject
  const promise = new Promise((yes, no) => { resolve = yes; reject = no })
  return { promise, resolve, reject }
}
const live = observable => observable.observers.filter(o => !o._willBeUnregistered).length
const transform = { position: { x: 0, y: 1.7, z: 0 }, orientation: { x: 0, y: 0, z: 0, w: 1 } }

async function setup(t, { compatible = Promise.resolve(), prepare = true } = {}) {
  const saved = new Map(['navigator', 'document', 'XRWebGLLayer', 'XRRigidTransform', 'fetch', 'PointerEvent'].map(name => [name, Object.getOwnPropertyDescriptor(globalThis, name)]))
  const sessions = [], states = [], errors = [], requested = deferred()
  let request = async () => makeSession(), layerError = null
  const global = (name, value) => Object.defineProperty(globalThis, name, { configurable: true, writable: true, value })
  global('navigator', { xr: { requestSession: (...args) => { sessions.push(args); requested.resolve(); return request() } } })
  global('document', Object.assign(new EventTarget(), { body: { contains: () => false } }))
  global('fetch', () => { throw new Error('Unexpected XR network request') })
  global('PointerEvent', class extends Event { constructor(type, options) { super(type); Object.assign(this, options) } })
  global('XRWebGLLayer', class {
    constructor() {
      if (layerError) throw layerError
      this.framebufferWidth = 800; this.framebufferHeight = 600; this.framebuffer = {}
    }
  })
  global('XRRigidTransform', class { constructor(position, orientation) { this.position = position; this.orientation = orientation } })
  const engine = new NullEngine(), scene = new Scene(engine)
  scene.useRightHandedSystem = true
  const camera = new FreeCamera('desktop', Vector3.Zero(), scene)
  const context = { makeXRCompatible: () => compatible }
  const canvas = { offsetWidth: 800, offsetHeight: 600, getContext: () => context,
    style: new Proxy({}, { set() { throw new Error('Unexpected inline style') } }) }
  engine.getRenderingCanvas = () => canvas
  const bytes = readFileSync(new URL('../../ui/public/assets/models/bd201855c8114b9b0e9cdd465d6f08413d18604894c839fb78d54d890c2adc94.glb', import.meta.url))
  const digest = createHash('sha256').update(bytes).digest('hex'), { costs, boundsMm } = validateGlb(bytes)
  const resources = createRenderResources(scene, { fetchAsset: async url => {
    assert.equal(url, `/assets/models/${digest}.glb`); return new Response(bytes)
  } })
  const model = { digest, profile: 'gltf2-static-v1', allowed: costs.map(n => Math.max(1, n)), bounds: boundsMm,
    scale: 1, pivot: [0, 0, 0], front: '-z' }
  let controllerScene
  const waiters = new Map()
  const lifecycle = createWorldXR(scene, {
    connect: experience => controllerScene.connect(experience),
    disconnect: () => controllerScene.disconnect(),
    cancel: () => controllerScene.cancel(),
    changed: state => { states.push(state); waiters.get(state)?.resolve(); waiters.delete(state) },
    error: cause => errors.push(cause),
  })
  controllerScene = createControllerScene(scene, resources,
    { axes() {}, snap() {}, teleport() {} }, { workspace: () => null, changed() {}, error: cause => errors.push(cause),
      guard: lifecycle.guard, menu: { open() {}, move() {}, commit() {}, cancel() {} } })
  const baseline = { scene: live(scene.onDisposeObservable), engine: live(engine.onDisposeObservable), cameras: scene.cameras.length }
  t.after(async () => {
    await lifecycle.dispose()
    controllerScene.dispose()
    resources.dispose()
    assert.deepEqual({ scene: live(scene.onDisposeObservable), engine: live(engine.onDisposeObservable), cameras: scene.cameras.length }, baseline)
    scene.dispose(); engine.dispose()
    for (const [name, descriptor] of saved) {
      if (descriptor) Object.defineProperty(globalThis, name, descriptor)
      else delete globalThis[name]
    }
  })
  if (prepare) await lifecycle.prepare()
  return { lifecycle, controllerScene, engine, scene, camera, errors, states, sessions, requested, context, model,
    request(fn) { request = fn }, layerError(value) { layerError = value },
    wait(state) { if (lifecycle.state === state) return Promise.resolve(); const d = deferred(); waiters.set(state, d); return d.promise },
    frame() {
      engine.customAnimationFrameRequester.renderFunction(1, { getViewerPose: () => ({ ...transform, transform, views: [] }),
        getPose: () => ({ transform }) })
    } }
}
function makeSession() {
  const session = Object.assign(new EventTarget(), { visibilityState: 'visible', ends: 0, inputSources: [],
    renderState: {}, requestAnimationFrame: () => 1, cancelAnimationFrame() {},
    requestReferenceSpace: async () => ({ getOffsetReferenceSpace() { return this } }),
    updateRenderState(value) { Object.assign(this.renderState, value) },
    async end() { this.ends++; this.dispatchEvent(new Event('end')) },
  })
  return session
}

test('prepares explicit owners without permissions, styles, profiles or optional features', async t => {
  const f = await setup(t)
  assert.equal(f.sessions.length, 0)
  assert.deepEqual(f.lifecycle.experience.baseExperience.featuresManager.getEnabledFeatures(), [])
  assert.equal(f.lifecycle.state, 'ready')
})

test('failed preparation releases its partial helper and can be prepared again', async t => {
  const f = await setup(t, { prepare: false }), browserXR = navigator.xr
  delete navigator.xr
  await assert.rejects(f.lifecycle.prepare(), /WebXR not supported/)
  assert.equal(f.lifecycle.experience, null)
  assert.equal(f.lifecycle.state, 'unavailable')
  navigator.xr = browserXR
  await f.lifecycle.prepare()
  assert.equal(f.lifecycle.state, 'ready')
})

test('disposal during preparation cannot install a late helper or request a session', async t => {
  const f = await setup(t, { prepare: false })
  const preparing = f.lifecycle.prepare()
  await f.lifecycle.dispose()
  await preparing
  assert.equal(f.lifecycle.state, 'disposed')
  assert.equal(f.lifecycle.experience, null)
  assert.equal(f.sessions.length, 0)
})

test('permission refusal retires failed helper and permits deliberate retry', async t => {
  const f = await setup(t), refused = new Error('permission refused')
  const first = f.lifecycle.experience
  f.request(async () => { throw refused })
  await assert.rejects(f.lifecycle.enter(), error => error === refused)
  assert.equal(f.lifecycle.state, 'ready')
  assert.notEqual(f.lifecycle.experience, first)
  f.request(async () => makeSession())
  await f.lifecycle.enter(); assert.equal(f.lifecycle.state, 'starting')
  assert.deepEqual(f.sessions.at(-1), ['immersive-vr', { optionalFeatures: ['local-floor'] }])
  f.frame(); assert.equal(f.lifecycle.state, 'presenting')
  await f.lifecycle.exit()
  assert.equal(f.lifecycle.state, 'ready')
})

for (const stage of ['init', 'before-capture', 'reference', 'layer', 'render-state', 'after-loop']) {
  test(`${stage} failure ends actual session, restores desktop and permits retry`, async t => {
    const f = await setup(t), session = makeSession(), cause = new Error(stage)
    f.request(async () => session)
    const helper = f.lifecycle.experience.baseExperience
    if (stage === 'init') helper.sessionManager.onXRSessionInit.add(() => { throw cause })
    if (stage === 'before-capture') helper.sessionManager.onXRSessionInit.add(() => { throw cause }, undefined, true)
    if (stage === 'reference') session.requestReferenceSpace = async () => { throw cause }
    if (stage === 'layer') f.layerError(cause)
    if (stage === 'render-state') session.updateRenderState = () => { throw cause }
    if (stage === 'after-loop') helper.onInitialXRPoseSetObservable.add(() => { throw cause })
    await assert.rejects(f.lifecycle.enter())
    assert.equal(session.ends, 1)
    assert.equal(helper.sessionManager.inXRSession, false)
    assert.equal(f.scene.activeCamera, f.camera)
    assert.equal(f.engine.customAnimationFrameRequester, null)
    assert.equal(f.lifecycle.state, 'ready')
    f.layerError(null); f.request(async () => makeSession())
    await f.lifecycle.enter(); f.frame(); await f.lifecycle.exit()
  })
}

test('cancel and dispose during consent join the original entry and end its late session once', async t => {
  const f = await setup(t), consent = deferred(), session = makeSession()
  f.request(() => consent.promise)
  const entering = f.lifecycle.enter()
  await f.requested.promise
  await assert.rejects(f.lifecycle.enter(), /not ready/)
  const exiting = f.lifecycle.exit(), disposing = f.lifecycle.dispose()
  consent.resolve(session)
  await Promise.all([entering.catch(() => {}), exiting, disposing])
  assert.equal(session.ends, 1)
  assert.equal(f.lifecycle.state, 'disposed')
  assert.equal(f.sessions.length, 1)
})

test('native end during pending layer setup waits for its continuation before retiring', async t => {
  const compatible = deferred(), session = makeSession()
  const g = await setup(t, { compatible: compatible.promise })
  const target = g.lifecycle.experience.renderTarget
  const requested = deferred()
  g.lifecycle.experience.baseExperience.sessionManager.onXRReferenceSpaceInitialized.addOnce(() => requested.resolve())
  g.request(async () => session)
  const entering = g.lifecycle.enter()
  await requested.promise
  session.dispatchEvent(new Event('end'))
  const exiting = g.lifecycle.exit()
  assert.equal(g.lifecycle.state, 'stopping')
  assert.equal(g.lifecycle.experience.renderTarget, target)
  compatible.resolve()
  await Promise.all([entering, exiting])
  assert.equal(session.ends, 0)
  assert.equal(g.scene.activeCamera, g.camera)
  assert.equal(g.lifecycle.state, 'ready')
})

test('end rejection blocks re-entry; later native end completes cleanup without another end request', async t => {
  const f = await setup(t), session = makeSession()
  session.end = async () => { session.ends++; throw new Error('device did not release') }
  f.request(async () => session)
  await f.lifecycle.enter(); f.frame()
  await assert.rejects(f.lifecycle.exit(), /release is unconfirmed/)
  assert.equal(f.lifecycle.state, 'blocked')
  await assert.rejects(f.lifecycle.enter(), /not ready/)
  const ready = f.wait('ready')
  session.dispatchEvent(new Event('end'))
  await ready
  assert.equal(session.ends, 1)
})

test('native end racing explicit exit wins over an already-ended rejection', async t => {
  const f = await setup(t), session = makeSession()
  session.end = async () => { session.ends++; session.dispatchEvent(new Event('end')); throw new Error('already ended') }
  f.request(async () => session)
  await f.lifecycle.enter(); f.frame()
  await Promise.all([f.lifecycle.exit(), f.lifecycle.exit()])
  assert.equal(session.ends, 1)
  assert.equal(f.lifecycle.state, 'ready')
})

for (const when of ['first', 'later']) test(`${when} frame callback failure stops the real session`, async t => {
  const f = await setup(t), session = makeSession()
  f.request(async () => session)
  await f.lifecycle.enter()
  if (when === 'later') f.frame()
  f.lifecycle.experience.baseExperience.sessionManager.onXRFrameObservable.add(f.lifecycle.guard(() => { throw new Error('frame failure') }))
  const ready = f.wait('ready')
  f.frame(); await ready
  assert.equal(session.ends, 1)
  assert.match(f.errors[0].message, /frame failure/)
})

test('real Vive decoders and controller adapter detach sources across end and re-entry', async t => {
  const f = await setup(t)
  const prepared = f.lifecycle.experience
  for (let cycle = 0; cycle < 3; cycle++) {
    const session = makeSession()
    f.request(async () => session)
    await f.lifecycle.enter(); f.frame()
    const controllers = []
    const added = deferred()
    prepared.input.onControllerAddedObservable.addOnce(controller => {
      controller.onMotionControllerInitObservable.addOnce(() => added.resolve())
    })
    const sources = ['left', 'right'].map(handedness => ({ profiles: ['htc-vive'], handedness, targetRayMode: 'tracked-pointer',
      gripSpace: {}, targetRaySpace: {}, gamepad: { buttons: Array.from({ length: 5 }, () => ({ pressed: false, touched: false, value: 0 })), axes: [0, 0] } }))
    session.dispatchEvent(Object.assign(new Event('inputsourceschange'), { added: sources, removed: [] }))
    await added.promise
    for (const controller of prepared.input.controllers) {
      controllers.push(controller)
      assert.equal(controller.motionController.profileId, 'htc-vive')
      assert.deepEqual(controller.motionController.getComponentIds(), ['xr-standard-trigger', 'xr-standard-squeeze', 'xr-standard-touchpad', 'menu'])
      assert.equal(Boolean(controller.motionController.rootMesh), false)
    }
    assert.equal(f.controllerScene.status.sources.length, 2)
    await f.lifecycle.exit()
    assert.equal(session.ends, 1)
    assert.equal(prepared.input.controllers.length, 0)
    assert.equal(f.controllerScene.status.sources.length, 0)
    assert.equal(f.lifecycle.experience, prepared)
    for (const controller of controllers) assert.equal(controller.onMotionControllerInitObservable.hasObservers(), false)
  }
})

test('real XRInput components drive scene picks and cancel on visibility loss or source departure', async t => {
  const f = await setup(t), session = makeSession()
  f.controllerScene.install({ digest: 'verified-view-boundary', roles: { navigation: 'left', menu: 'right' },
    profiles: [{ names: ['htc-vive'], model: f.model,
      components: [{ name: 'trigger', id: 'xr-standard-trigger', type: 'trigger', features: ['press'] }] }],
    bindings: [{ id: 'select', role: 'any', component: 'trigger', kind: 'press_release', action: 'select' }] })
  const plane = MeshBuilder.CreatePlane('target', { size: 2, sideOrientation: 2 }, f.scene)
  plane.position.set(0, 1.7, -1); plane.computeWorldMatrix(true)
  let picks = 0
  f.scene.onPointerObservable.add(() => picks++, PointerEventTypes.POINTERPICK)
  f.request(async () => session)
  await f.lifecycle.enter(); f.frame()
  const source = { profiles: ['htc-vive'], handedness: 'left', targetRayMode: 'tracked-pointer',
    gripSpace: {}, targetRaySpace: {}, gamepad: { buttons: Array.from({ length: 5 }, () => ({ pressed: false, value: 0 })), axes: [0, 0] } }
  const initialized = deferred()
  f.lifecycle.experience.input.onControllerAddedObservable.addOnce(c => c.onMotionControllerInitObservable.addOnce(() => initialized.resolve()))
  session.dispatchEvent(Object.assign(new Event('inputsourceschange'), { added: [source], removed: [] }))
  await initialized.promise
  const frame = pressed => { source.gamepad.buttons[0] = { pressed, value: Number(pressed) }; f.frame() }
  frame(false); frame(true); frame(false)
  assert.equal(picks, 1)
  frame(true)
  session.visibilityState = 'hidden'; session.dispatchEvent(new Event('visibilitychange'))
  assert.equal(f.controllerScene.status.sources[0].tracked, false)
  session.visibilityState = 'visible'; session.dispatchEvent(new Event('visibilitychange'))
  frame(false)
  assert.equal(picks, 1)
  frame(true)
  session.dispatchEvent(Object.assign(new Event('inputsourceschange'), { added: [], removed: [source] }))
  assert.equal(f.controllerScene.status.sources.length, 0)
  assert.equal(picks, 1)
  await f.lifecycle.exit()
  assert.deepEqual(f.errors, [])
})

test('source callback exception is contained and releases its session', async t => {
  const f = await setup(t), session = makeSession()
  f.request(async () => session)
  await f.lifecycle.enter(); f.frame()
  const ready = f.wait('ready')
  f.lifecycle.experience.input.onControllerAddedObservable.add(f.lifecycle.guard(() => { throw new Error('source failure') }))
  session.dispatchEvent(Object.assign(new Event('inputsourceschange'), { added: [{ profiles: [], targetRayMode: 'gaze', targetRaySpace: {} }], removed: [] }))
  await ready
  assert.equal(session.ends, 1)
  assert.match(f.errors[0].message, /source failure/)
})

test('disposal retains dependencies after end rejection until native release arrives', async t => {
  const f = await setup(t), session = makeSession()
  session.end = async () => { session.ends++; throw new Error('release refused') }
  f.request(async () => session)
  await f.lifecycle.enter(); f.frame()
  const blocked = f.wait('blocked'), disposal = f.lifecycle.dispose()
  await blocked
  assert.ok(f.lifecycle.experience)
  session.dispatchEvent(new Event('end'))
  await disposal
  assert.equal(session.ends, 1)
  assert.equal(f.lifecycle.experience, null)
  assert.equal(f.lifecycle.state, 'disposed')
})

test('successful end promise does not dispose ahead of native end dispatch', async t => {
  const f = await setup(t), session = makeSession(), called = deferred()
  session.end = async () => { session.ends++; called.resolve() }
  f.request(async () => session)
  await f.lifecycle.enter(); f.frame()
  const exiting = f.lifecycle.exit()
  await called.promise
  assert.equal(f.lifecycle.state, 'stopping')
  assert.ok(f.lifecycle.experience)
  session.dispatchEvent(new Event('end'))
  await exiting
  assert.equal(session.ends, 1)
  assert.equal(f.lifecycle.state, 'ready')
})

test('end refusal is visible while layer setup remains pending', async t => {
  const compatible = deferred(), f = await setup(t, { compatible: compatible.promise }), session = makeSession()
  session.end = async () => { session.ends++; throw new Error('release refused during setup') }
  f.request(async () => session)
  const initialized = deferred()
  f.lifecycle.experience.baseExperience.sessionManager.onXRReferenceSpaceInitialized.addOnce(() => initialized.resolve())
  const entering = f.lifecycle.enter()
  await initialized.promise
  const blocked = f.wait('blocked'), exiting = f.lifecycle.exit()
  await blocked
  assert.match(f.errors[0].message, /release is unconfirmed/)
  assert.ok(f.lifecycle.experience)
  session.dispatchEvent(new Event('end'))
  compatible.resolve()
  await Promise.all([entering, exiting])
  assert.equal(session.ends, 1)
  assert.equal(f.lifecycle.state, 'ready')
})
