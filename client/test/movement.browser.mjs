import { EngineStore } from '@babylonjs/core/Engines/engineStore.js'
import { createWorld } from '../src/world-scene.js'
import { readControl } from '../src/locomotion.js'

// A browser rendering/lifecycle gate. Physics and signed authority are covered
// by real-owner EUnit tests; this fixture does not impersonate those owners.
export async function runMovementSmoke(canvas) {
  const errors = [], inputs = []
  const world = createWorld(canvas, () => {}, () => {}, error => errors.push(error.message))
  const scene = EngineStore.LastCreatedScene
  // Offscreen browser sessions may suspend requestAnimationFrame. Exercise
  // the same public renderer explicitly, without pretending to test XR timing.
  const rendered = async () => { scene.render() }
  const check = (condition, message) => { if (!condition) throw new Error(message) }
  try {
    const current = { fence: 'fixture', marks: [],
      control: readControl('control(human,1,controlled_agent(vehicle,1,2,1,motion(grounded(700),2000,1600,500,query_limits(2,0,8,128),[snap(785),teleport(6000,2000,700)]),viewpoint(cockpit,pose(vector(500,300,0),rotation(0,785,0)),tracking(view_only,500))))'),
      poses: new Map([['2:1', { position: [0, 1, 0], rotation: [0, 0, 0, 1] }]]),
      feedback: { sequence: '-1', result: 'idle' }, clearance: 0.4,
      command: async input => { inputs.push(input); return true } }
    world.simulation(current)
    await rendered()
    const camera = scene.getCameraByName('observer')
    check(Object.keys(camera.inputs.attached).join() === 'mouse', 'direct camera translation remains attached')
    check(Math.abs(camera.globalPosition.x - 0.5) < 0.001, 'authored camera X offset was lost')
    check(Math.abs(camera.globalPosition.y - 1.3) < 0.001, 'authored camera Y offset was lost')
    current.poses.set('2:1', { position: [2, 1, 0], rotation: [0, 0, 0, 1] })
    world.simulation(current)
    await rendered()
    check(Math.abs(camera.globalPosition.x - 2.5) < 0.001, 'accepted physical correction did not reach the camera')
    world.simulation(null)
    await rendered()
    check(Object.keys(camera.inputs.attached).join() === 'mouse', 'unavailable world enabled observer travel')
    world.simulation(undefined)
    await rendered()
    check(Boolean(camera.inputs.attached.keyboard), 'leaving physical view did not restore observer input')
    check(errors.length === 0, `scene resource failure: ${errors.join(', ')}`)
    return { renderer: scene.getEngine().description, errors, commands: inputs.length,
      immersiveVR: await navigator.xr?.isSessionSupported('immersive-vr') ?? false,
      checks: ['authored camera mount', 'accepted pose correction', 'disabled direct translation',
        'unavailable world freezes travel', 'observer restoration', 'scene disposal'] }
  } finally { world.dispose() }
}
