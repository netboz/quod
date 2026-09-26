import { Engine } from '@babylonjs/core/Engines/engine.js'
import { Scene } from '@babylonjs/core/scene.js'
import { ArcRotateCamera } from '@babylonjs/core/Cameras/arcRotateCamera.js'
import { HemisphericLight } from '@babylonjs/core/Lights/hemisphericLight.js'
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js'
import { Color3 } from '@babylonjs/core/Maths/math.color.js'
import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder.js'
import { StandardMaterial } from '@babylonjs/core/Materials/standardMaterial.js'
import { DynamicTexture } from '@babylonjs/core/Materials/Textures/dynamicTexture.js'
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js'
// Babylon's modular build registers picking separately from scene rendering.
import '@babylonjs/core/Culling/ray.js'
import { PointerEventTypes } from '@babylonjs/core/Events/pointerEvents.js'
import { PALETTE } from './palette.js'
import { paintMarks, clearMarks } from './scene.js'
import { createProofPanel } from './proof-panel.js'
import { WebXRState } from '@babylonjs/core/XR/webXRTypes.js'

const MENU_RADIUS = 0.36
const MENU_DEAD_ZONE = 0.24

// Sector zero starts at the top and proceeds clockwise, matching the visual
// layout. Returning null inside the dead zone lets a user press the pad before
// committing to an action.
export function radialIndex({ x, y }, count, deadZone = MENU_DEAD_ZONE) {
  if (!Number.isInteger(count) || count < 1 || Math.hypot(x, y) < deadZone) return null
  const sector = 2 * Math.PI / count
  const clockwiseFromTop = (Math.atan2(x, -y) + 2 * Math.PI) % (2 * Math.PI)
  return Math.floor((clockwiseFromTop + sector / 2) / sector) % count
}

// The camera and lighting belong to this viewing session. All visible model
// geometry comes from the ontology projection, including the lobby floor.
export function createWorld(canvas, onPick, onImmersiveChanged = () => {}) {
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
  let menu = { entries: [], activate: null, root: null, items: [], selected: null }
  let workspace = null
  let panel = null
  let immersive = false
  scene.onPointerObservable.add(info => {
    let node = info.pickInfo?.pickedMesh
    if (node?.metadata?.menuEntry) {
      menu.activate?.(node.metadata.menuEntry)
      closeMenu()
      return
    }
    while (node && !node.metadata?.depicts) node = node.parent
    if (node?.metadata?.depicts?.anchor) onPick(node.metadata.depicts)
  }, PointerEventTypes.POINTERPICK)
  let painted = new Map()
  let xr = null

  function closeMenu() {
    menu.root?.dispose(false, true)
    menu = { ...menu, root: null, items: [], selected: null }
  }

  function selectMenuEntry(index) {
    if (index !== null && (index < 0 || index >= menu.items.length)) return
    menu.selected = index
    for (let position = 0; position < menu.items.length; position += 1) {
      const { texture, entry } = menu.items[position]
      drawMenuLabel(texture, entry.label, position === index)
    }
  }

  function openMenu(axes = { x: 0, y: -1 }) {
    closeMenu()
    if (workspace || menu.entries.length === 0 || !scene.activeCamera) return
    const root = new TransformNode('action-menu', scene)
    const cameraPosition = scene.activeCamera.globalPosition
    const direction = scene.activeCamera.getForwardRay().direction
    root.position.copyFrom(cameraPosition.add(direction.scale(1.15)))
    root.lookAt(cameraPosition, Math.PI)
    const count = menu.entries.length
    const items = menu.entries.map((entry, index) => {
      const angle = index * 2 * Math.PI / count
      const plane = MeshBuilder.CreatePlane(`action-menu:${entry.id}`, {
        width: 0.46, height: 0.18,
      }, scene)
      plane.parent = root
      plane.position.set(Math.sin(angle) * MENU_RADIUS,
                         Math.cos(angle) * MENU_RADIUS, 0)
      plane.metadata = { menuEntry: entry }
      const texture = new DynamicTexture(`action-menu-texture:${entry.id}`,
        { width: 512, height: 192 }, scene, false)
      texture.hasAlpha = true
      const material = new StandardMaterial(`action-menu-material:${entry.id}`, scene)
      material.diffuseTexture = texture
      material.emissiveTexture = texture
      material.opacityTexture = texture
      material.disableLighting = true
      material.backFaceCulling = false
      plane.material = material
      return { entry, texture }
    })
    menu = { ...menu, root, items, selected: null }
    const initial = radialIndex(axes, count)
    if (initial !== null) selectMenuEntry(initial)
    else for (const item of items) drawMenuLabel(item.texture, item.entry.label, false)
  }

  function bindRadialControl(controller) {
    const bind = motionController => {
      const component = motionController.getComponentOfType('touchpad') ??
        motionController.getComponentOfType('thumbstick')
      if (!component) return
      let pressed = component.pressed
      component.onAxisValueChangedObservable.add(axes => {
        if (menu.root) selectMenuEntry(radialIndex(axes, menu.entries.length))
      })
      component.onButtonStateChangedObservable.add(current => {
        if (current.pressed === pressed) return
        pressed = current.pressed
        if (pressed) {
          openMenu(current.axes)
        } else if (menu.root) {
          const entry = menu.entries[menu.selected]
          closeMenu()
          if (entry) menu.activate?.(entry)
        }
      })
    }
    if (controller.motionController) bind(controller.motionController)
    else controller.onMotionControllerInitObservable.addOnce(bind)
  }

  const resize = () => engine.resize()
  function showWorkspace() {
    if (workspace && immersive) {
      panel ??= createProofPanel(scene)
      panel.update(workspace, true)
    } else if (panel) {
      panel.dispose()
      panel = null
    }
  }
  window.addEventListener('resize', resize)
  engine.runRenderLoop(() => scene.render())
  return {
    paint(marks) { painted = paintMarks(scene, marks, painted) },
    setActionMenu(entries, activate) {
      closeMenu()
      menu = { ...menu, entries: [...entries], activate }
    },
    setWorkspace(model) {
      workspace = model
      if (model) closeMenu()
      showWorkspace()
    },
    async immersive() {
      if (!xr) {
        await import('@babylonjs/core/XR/webXRDefaultExperience.js')
        const floor = painted.get('floor')?.node
        xr = await scene.createDefaultXRExperienceAsync({ floorMeshes: floor ? [floor] : [] })
        xr.baseExperience.onStateChangedObservable.add(state => {
          immersive = state === WebXRState.IN_XR
          closeMenu()
          showWorkspace()
          onImmersiveChanged(immersive)
        })
        for (const controller of xr.input.controllers) bindRadialControl(controller)
        xr.input.onControllerAddedObservable.add(bindRadialControl)
      }
      await xr.baseExperience.enterXRAsync('immersive-vr', 'local-floor')
    },
    dispose() {
      window.removeEventListener('resize', resize)
      panel?.dispose()
      painted = clearMarks(painted)
      scene.dispose()
      engine.dispose()
    },
  }
}

function drawMenuLabel(texture, label, selected) {
  texture.getContext().clearRect(0, 0, texture.getSize().width, texture.getSize().height)
  texture.drawText(label, null, 122, 'bold 54px system-ui, sans-serif',
                   selected ? PALETTE.navy : '#F5F1EB',
                   selected ? PALETTE.gold : '#243744', true, true)
}
