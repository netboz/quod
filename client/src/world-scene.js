import { Engine } from '@babylonjs/core/Engines/engine.js'
import { Scene } from '@babylonjs/core/scene.js'
import { ArcRotateCamera } from '@babylonjs/core/Cameras/arcRotateCamera.js'
import { HemisphericLight } from '@babylonjs/core/Lights/hemisphericLight.js'
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js'
import { Color3 } from '@babylonjs/core/Maths/math.color.js'
// Babylon's modular build registers picking separately from scene rendering.
import '@babylonjs/core/Culling/ray.js'
import { PointerEventTypes } from '@babylonjs/core/Events/pointerEvents.js'
import { PALETTE } from './palette.js'
import { paintMarks, clearMarks } from './scene.js'

// The camera and lighting belong to this viewing session. All visible model
// geometry comes from the ontology projection, including the lobby floor.
export function createWorld(canvas, onPick) {
  const engine = new Engine(canvas, true, { stencil: true })
  const scene = new Scene(engine)
  const sky = Color3.FromHexString(PALETTE.navy).scale(0.34)
  scene.clearColor.set(sky.r, sky.g, sky.b, 1)
  const camera = new ArcRotateCamera('observer', -Math.PI / 2, Math.PI / 2.4,
    5.8, new Vector3(0, 1.1, 0), scene)
  camera.lowerRadiusLimit = 1
  camera.upperRadiusLimit = 40
  camera.attachControl(canvas, true)
  const light = new HemisphericLight('sky', new Vector3(0.2, 1, -0.3), scene)
  light.intensity = 1.2
  scene.onPointerObservable.add(info => {
    let node = info.pickInfo?.pickedMesh
    while (node && !node.metadata?.depicts) node = node.parent
    if (node?.metadata?.depicts?.anchor) onPick(node.metadata.depicts)
  }, PointerEventTypes.POINTERPICK)
  let painted = new Map()
  let xr = null
  const resize = () => engine.resize()
  window.addEventListener('resize', resize)
  engine.runRenderLoop(() => scene.render())
  return {
    paint(marks) { painted = paintMarks(scene, marks, painted) },
    async immersive() {
      if (!xr) {
        await import('@babylonjs/core/XR/webXRDefaultExperience.js')
        const floor = painted.get('floor')?.node
        xr = await scene.createDefaultXRExperienceAsync({ floorMeshes: floor ? [floor] : [] })
      }
      await xr.baseExperience.enterXRAsync('immersive-vr', 'local-floor')
    },
    dispose() {
      window.removeEventListener('resize', resize)
      painted = clearMarks(painted)
      scene.dispose()
      engine.dispose()
    },
  }
}
