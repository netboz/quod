// Offline asset inspection using the existing GLB admission and scene renderer.
import { Engine } from '@babylonjs/core/Engines/engine.js'
import { Scene } from '@babylonjs/core/scene.js'
import { ArcRotateCamera } from '@babylonjs/core/Cameras/arcRotateCamera.js'
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js'
import { Color4 } from '@babylonjs/core/Maths/math.color.js'
import { HemisphericLight } from '@babylonjs/core/Lights/hemisphericLight.js'
import { DirectionalLight } from '@babylonjs/core/Lights/directionalLight.js'
import { createRenderResources } from '../src/render-resources.js'
import { paintMarks } from '../src/scene.js'

const canvas = document.getElementById('roof')
const status = document.getElementById('status')
const asset = new URL('../../assets/lobby/roof-six-feet.glb', import.meta.url)
document.getElementById('download').href = asset.href
const groundAsset = new URL('../../assets/lobby/ground.glb', import.meta.url)
document.getElementById('download-ground').href = groundAsset.href
const engine = new Engine(canvas, true)
const scene = new Scene(engine)
scene.useRightHandedSystem = true
scene.clearColor = new Color4(0.84, 0.875, 0.89, 1)
const camera = new ArcRotateCamera('inspection', -Math.PI/2.4, 1.13, 25, new Vector3(0,2.3,0), scene)
camera.minZ = 0.05
camera.lowerRadiusLimit = 3
camera.upperRadiusLimit = 35
camera.wheelPrecision = 35
camera.attachControl(canvas, true)
const fill = new HemisphericLight('fill', new Vector3(0,1,0), scene)
fill.intensity = 0.65
fill.groundColor.set(0.55,0.60,0.67)
const key = new DirectionalLight('key', new Vector3(-0.4,-1,0.6), scene)
key.intensity = 0.8
const assets = new Map()
const resources = createRenderResources(scene, { fetchAsset: (path, options) => fetch(assets.get(path), options) })
let painted = new Map()
engine.runRenderLoop(() => scene.render())
window.addEventListener('resize', () => engine.resize())
for (const button of document.querySelectorAll('[data-view]')) button.onclick = () => {
  const views = { orbit: [-Math.PI/2.4,1.13,25,2.3], front: [0,Math.PI/2,25,2.5],
    top: [-Math.PI/2,0.01,27,2.3], inside: [-Math.PI/2.4,2.0,22,3.0] }
  const [alpha,beta,radius,y] = views[button.dataset.view]
  camera.setTarget(new Vector3(0,y,0))
  camera.alpha = alpha; camera.beta = beta; camera.radius = radius
}
document.getElementById('wireframe').onclick = event => {
  const enabled = event.currentTarget.getAttribute('aria-pressed') !== 'true'
  event.currentTarget.setAttribute('aria-pressed', String(enabled))
  for (const material of scene.materials) material.wireframe = enabled
}
for (const button of document.querySelectorAll('[data-asset]')) button.onclick = () => {
  const enabled = button.getAttribute('aria-pressed') !== 'true'
  button.setAttribute('aria-pressed',String(enabled))
  for (const root of painted.get(button.dataset.asset)?.instance?.rootNodes ?? []) root.setEnabled(enabled)
}
window.roofReady = (async () => {
  const reports = await Promise.all(['roof-six-feet','ground'].map(name =>
    fetch(new URL(`../../assets/lobby/${name}.json`, import.meta.url)).then(r => r.json())))
  const marks = reports.map((report,i) => {
    const {digest,profile,costs,boundsMm} = report.output
    assets.set(`/assets/models/${digest}.glb`,i === 0 ? asset : groundAsset)
    return {id:i === 0 ? 'roof' : 'ground',kind:'mesh',parent:null,
      // Admission requires positive allowances even for untextured assets.
      size:{digest,profile,allowed:costs.map(n => Math.max(1,n)),bounds:boundsMm,pivot:[0,0,0],front:'-z',scale:1},
      transform:{x:0,y:0,z:0,rx:0,ry:0,rz:0},material:null,label:null,depicts:null}
  })
  painted = paintMarks(scene, marks, painted, resources, error => { status.textContent = String(error) })
  await Promise.all([...painted.values()].map(entry => entry.model.ready))
  await scene.whenReadyAsync()
  scene.render()
  status.textContent = '6 feet seated on border · 18 m ground · 4.4 m opening · 1 m outer border · separate meshes'
  return reports.map(report => ({...report.output,checks:report.checks}))
})().catch(error => { status.textContent = `Could not load roof: ${error.message}`; throw error })
