import { createWorld } from '../src/world-scene.js'
import { EngineStore } from '@babylonjs/core/Engines/engineStore.js'
import { validateGlb } from '../src/glb-profile.js'

// Software fixture only: replace browser XR boundaries, never Babylon owners.
// This does not establish permissions, production CSP, stereo or hardware support.
export async function createXRWorldFixture(canvas, modes) {
  const savedXR = Object.getOwnPropertyDescriptor(navigator, 'xr')
  const savedLayer = Object.getOwnPropertyDescriptor(globalThis, 'XRWebGLLayer')
  let world, room, compatible, ready, initialized, errors = []
  let tracked = false, ends = 0
  const pose = { position: { x: 0, y: 1.7, z: 0 }, orientation: { x: 0, y: 0, z: 0, w: 1 } }
  const session = Object.assign(new EventTarget(), {
    visibilityState: 'visible', renderState: {}, requestAnimationFrame: () => 1,
    cancelAnimationFrame() {}, requestReferenceSpace: async () => ({ getOffsetReferenceSpace() { return this } }),
    updateRenderState(value) { Object.assign(this.renderState, value) },
    async end() { ends++; session.dispatchEvent(new Event('end')) },
  })
  const source = { profiles: ['htc-vive'], handedness: 'right', targetRayMode: 'tracked-pointer',
    gripSpace: {}, targetRaySpace: {}, gamepad: { buttons: Array.from({ length: 5 }, () => ({ pressed: false, value: 0 })), axes: [0, 0] } }
  const restore = async () => {
    await world?.dispose()
    if (compatible) delete compatible.makeXRCompatible
    if (savedXR) Object.defineProperty(navigator, 'xr', savedXR)
    else delete navigator.xr
    if (savedLayer) Object.defineProperty(globalThis, 'XRWebGLLayer', savedLayer)
    else delete globalThis.XRWebGLLayer
  }
  try {
    Object.defineProperty(navigator, 'xr', { configurable: true, value: { requestSession: async () => session } })
    Object.defineProperty(globalThis, 'XRWebGLLayer', { configurable: true, value: class {
      constructor() { this.framebuffer = null; this.framebufferWidth = canvas.width; this.framebufferHeight = canvas.height }
    } })
    const prepared = new Promise(resolve => { ready = resolve })
    world = createWorld(canvas, () => {}, value => modes.push(value), error => errors.push(error), () => {},
      () => { if (world?.controllerStatus().sources.some(s => s.bindings.includes('menu'))) initialized?.() },
      state => { if (state === 'ready' || state === 'unavailable') ready() })
    room = EngineStore.LastCreatedScene
    compatible = canvas.getContext('webgl2') ?? canvas.getContext('webgl')
    compatible.makeXRCompatible = async () => {}
    await prepared
    if (errors.length) throw errors[0]
    const digest = 'bd201855c8114b9b0e9cdd465d6f08413d18604894c839fb78d54d890c2adc94'
    const bytes = await (await fetch(`/assets/models/${digest}.glb`)).arrayBuffer()
    const { costs, boundsMm } = validateGlb(bytes)
    world.setControllerMapping({ digest: 'fixture-view', roles: { navigation: 'left', menu: 'right' },
      profiles: [{ names: ['htc-vive'], components: [{ name: 'pad', id: 'xr-standard-touchpad', type: 'touchpad', features: ['press', 'axes2'] }],
        model: { digest, profile: 'gltf2-static-v1', allowed: costs.map(n => Math.max(1, n)), bounds: boundsMm,
          scale: 1, pivot: [0, 0, 0], front: '-z' } }],
      bindings: [{ id: 'menu', role: 'menu', component: 'pad', kind: 'radial', action: 'menu', threshold: 0.24 }] })
    await world.immersive()
    const frame = () => room.getEngine().customAnimationFrameRequester.renderFunction(1, {
      getViewerPose: () => tracked ? { transform: pose, views: [] } : null,
      getPose: () => tracked ? { transform: pose } : null,
    })
    frame()
    const inputReady = new Promise(resolve => { initialized = resolve })
    session.dispatchEvent(Object.assign(new Event('inputsourceschange'), { added: [source], removed: [] }))
    await inputReady
    return { world, room, frame, errors, restore, exits: () => ends,
      tracking(value) { tracked = value },
      position(x, y, z) { pose.position = { x, y, z } },
      press(pressed, { x, y }) {
        source.gamepad.buttons[2] = { pressed, value: Number(pressed) }
        source.gamepad.axes = [x, y]
        frame()
      } }
  } catch (error) { await restore(); throw error }
}
