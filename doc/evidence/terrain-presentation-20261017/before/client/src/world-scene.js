import { Engine } from '@babylonjs/core/Engines/engine.js'
import { Scene } from '@babylonjs/core/scene.js'
import { UniversalCamera } from '@babylonjs/core/Cameras/universalCamera.js'
import { HemisphericLight } from '@babylonjs/core/Lights/hemisphericLight.js'
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js'
import { Color3, Color4 } from '@babylonjs/core/Maths/math.color.js'
import { Layer } from '@babylonjs/core/Layers/layer.js'
import { Ray } from '@babylonjs/core/Culling/ray.js'
import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder.js'
import { StandardMaterial } from '@babylonjs/core/Materials/standardMaterial.js'
import { DynamicTexture } from '@babylonjs/core/Materials/Textures/dynamicTexture.js'
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js'
// Babylon's modular build registers picking separately from scene rendering.
import '@babylonjs/core/Culling/ray.js'
import { PointerEventTypes } from '@babylonjs/core/Events/pointerEvents.js'
import { PALETTE } from './palette.js'
import { paintMarks, clearMarks, paintBodyPoses, paintTerrain } from './scene.js'
import { createRenderResources } from './render-resources.js'
import { createWorkspacePanel } from './workspace-panel.js'
import { configureDesktopCamera, createMovementSpeed, createPointerLock } from './navigation.js'
import { WebXRState, WebXRTrackingState } from '@babylonjs/core/XR/webXRTypes.js'
import { createControlledNavigation } from './controlled-navigation.js'

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
export function createWorld(canvas, onPick, onImmersiveChanged = () => {},
  onResourceError = () => {}, onNavigationChanged = () => {}) {
  const engine = new Engine(canvas, true, { stencil: true })
  const scene = new Scene(engine)
  scene.useRightHandedSystem = true
  const resources = createRenderResources(scene)
  const sky = Color3.FromHexString(PALETTE.navy).scale(0.34)
  scene.clearColor.set(sky.r, sky.g, sky.b, 1)
  const camera = new UniversalCamera('observer', new Vector3(0, 1.7, -5.8), scene)
  camera.setTarget(new Vector3(0, 1.1, 0))
  configureDesktopCamera(camera)
  camera.attachControl(canvas)
  const movementSpeed = createMovementSpeed(canvas, camera)
  const navigation = createPointerLock(canvas, {
    onChanged: onNavigationChanged,
    onError: onResourceError,
  })
  const light = new HemisphericLight('sky', new Vector3(0.2, 1, -0.3), scene)
  light.intensity = 1.2
  let menu = { entries: [], activate: null, root: null, items: [], selected: null }
  let workspace = null
  let panel = null
  const appearanceSettings = { opacity: 0.78, scale: 1, distance: 1.6 }
  let immersive = false
  const contactMask = new Layer('physical-view-contact', null, scene, false, new Color4(1, 1, 1, 1))
  const contactText = new DynamicTexture('physical-view-contact-text', { width: 2048, height: 1024 }, scene, false)
  contactMask.texture = contactText
  contactMask.isEnabled = false
  let maskText = null
  const playerNavigation = createControlledNavigation(scene, camera, canvas, {
    active: navigation.active,
    blocked: () => Boolean(workspace || menu.root),
    mask: (visible, text) => {
      contactMask.isEnabled = visible
      if (visible && text !== maskText) {
        maskText = text
        contactText.drawText(text, null, 540, '40px system-ui, sans-serif', '#FFFFFF', '#000000', true, true)
      }
    },
    feedback: text => {
      onResourceError(new Error(text))
      if (immersive) for (const controller of xr?.input.controllers ?? []) {
        void controller.motionController?.pulse(0.25, 50)
      }
    },
  })
  scene.onBeforeRenderObservable.add(() => playerNavigation.render())
  scene.onPointerObservable.add(info => {
    const pick = navigation.active()
      ? scene.pick(engine.getRenderWidth() / 2, engine.getRenderHeight() / 2)
      : info.pickInfo
    let node = pick?.pickedMesh
    if (node?.metadata?.menuEntry) {
      menu.activate?.(node.metadata.menuEntry)
      closeMenu()
      return
    }
    while (node && !node.metadata?.depicts) node = node.parent
    if (node?.metadata?.depicts?.anchor) onPick(node.metadata.depicts)
  }, PointerEventTypes.POINTERPICK)
  let painted = new Map()
  let currentMarks = null
  let coordinateFrame = null
  let simulation = null, terrainCamera = null, terrainObserver = null, ordinaryFar = null
  let xr = null

  function cameraInterest() {
    const active = scene.activeCamera
    if (simulation?.selection === 'active' && active) simulation.interest?.(active.globalPosition.asArray())
  }
  function terrainHorizon() {
    const root = simulation?.marks.find(mark => mark.kind === 'terrain')
    const distance = simulation?.selection === 'active' && root ? root.size.viewDistance[0] / 1000 : null
    scene.fogMode = distance === null ? Scene.FOGMODE_NONE : Scene.FOGMODE_LINEAR
    if (distance !== null) {
      scene.fogColor.copyFrom(sky); scene.fogStart = distance * 0.75; scene.fogEnd = distance
    }
    if (terrainCamera) terrainCamera.maxZ = distance ?? ordinaryFar
  }
  function bindTerrainCamera() {
    if (terrainCamera) {
      terrainCamera.onViewMatrixChangedObservable.remove(terrainObserver)
      terrainCamera.maxZ = ordinaryFar
    }
    terrainCamera = scene.activeCamera
    ordinaryFar = terrainCamera?.maxZ ?? null
    terrainObserver = terrainCamera?.onViewMatrixChangedObservable.add(cameraInterest) ?? null
    terrainHorizon()
    cameraInterest()
  }
  scene.onActiveCameraChanged.add(bindTerrainCamera)
  bindTerrainCamera()

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
    root.lookAt(cameraPosition)
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
      if (controller.inputSource.handedness === 'left') {
        const squeeze = motionController.getComponentOfType('squeeze')
        let down = component.pressed
        const smooth = () => playerNavigation.axes(squeeze?.pressed ? component.axes : { x: 0, y: 0 })
        component.onAxisValueChangedObservable.add(smooth)
        squeeze?.onButtonStateChangedObservable.add(smooth)
        component.onButtonStateChangedObservable.add(current => {
          smooth()
          const clicked = current.pressed && !down
          down = current.pressed
          if (!clicked || squeeze?.pressed || !playerNavigation.controlled()) return
          const { x, y } = current.axes
          if (Math.abs(x) > 0.5 && Math.abs(x) > Math.abs(y)) playerNavigation.snap(x)
          else if (y < -0.5) {
            const ray = new Ray(Vector3.Zero(), Vector3.Forward())
            controller.getWorldPointerRayToRef(ray)
            playerNavigation.teleport(ray.direction)
          }
        })
        // Left-hand gestures belong to locomotion; the right-hand pad retains
        // the action menu. A missing component never becomes a guessed button.
        return
      }
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
      if (!panel && xr.baseExperience.camera.trackingState !== WebXRTrackingState.TRACKING) return
      panel ??= createWorkspacePanel(scene, appearanceSettings, resources)
      panel.update(workspace, true)
    } else if (panel) {
      panel.dispose()
      panel = null
    }
  }
  window.addEventListener('resize', resize)
  engine.runRenderLoop(() => scene.render())
  return {
    update(current) {
      simulation = null
      if (current?.selection === 'active') {
        if (coordinateFrame?.fence === current.fence && coordinateFrame.originSeq !== current.originSeq) {
          playerNavigation.rebase(Vector3.FromArray(current.origin.map((n, i) =>
            Number(coordinateFrame.origin[i] - n) / 1000)))
        }
        coordinateFrame = { fence: current.fence, originSeq: current.originSeq, origin: current.origin }
      } else if (current) coordinateFrame = null
      const observer = current?.selection === 'nonphysical' ||
        (current?.selection === 'active' && current.control === null)
      playerNavigation.update(observer ? undefined : current?.selection === 'active' && current.terrainReady !== false ? current : null)
      if (current && current.marks !== currentMarks) {
        painted = paintMarks(scene, current.marks, painted, resources, onResourceError)
        currentMarks = current.marks
      }
      if (current) paintBodyPoses(painted, current.poses ?? new Map())
      simulation = current
      terrainHorizon()
      scene.activeCamera?.getViewMatrix(true)
      cameraInterest()
      return paintTerrain(scene, painted, current, resources, onResourceError)
    },
    setActionMenu(entries, activate) {
      closeMenu()
      menu = { ...menu, entries: [...entries], activate }
    },
    setWorkspace(model) {
      workspace = model
      if (model) {
        navigation.release()
        closeMenu()
      }
      showWorkspace()
    },
    releaseNavigation() { navigation.release() },
    async immersive() {
      navigation.release()
      if (!xr) {
        await import('@babylonjs/core/Loading/Plugins/babylonFileLoader.js')
        await import('@babylonjs/loaders/glTF/index.js')
        await import('@babylonjs/core/Materials/Node/Blocks/index.js')
        await import('@babylonjs/core/Materials/colorCurves.js')
        await import('@babylonjs/core/XR/features/WebXRControllerPointerSelection.js')
        await import('@babylonjs/core/XR/features/WebXRNearInteraction.js')
        await import('@babylonjs/core/XR/features/WebXRHandTracking.js')
        const { WebXRDefaultExperience } = await import('@babylonjs/core/XR/webXRDefaultExperience.js')
        xr = await WebXRDefaultExperience.CreateAsync(scene, { disableTeleportation: true })
        xr.baseExperience.camera.onTrackingStateChanged.add(state => {
          if (state === WebXRTrackingState.TRACKING) {
            // The notice precedes the camera pose update; place after that update.
            scene.onBeforeRenderObservable.addOnce(showWorkspace)
          }
        })
        xr.baseExperience.onStateChangedObservable.add(state => {
          immersive = state === WebXRState.IN_XR
          playerNavigation.xr(immersive ? xr.baseExperience.camera : null)
          closeMenu()
          showWorkspace()
          onImmersiveChanged(immersive)
        })
        for (const controller of xr.input.controllers) bindRadialControl(controller)
        xr.input.onControllerAddedObservable.add(bindRadialControl)
        xr.input.onControllerRemovedObservable.add(() => playerNavigation.axes({ x: 0, y: 0 }))
      }
      await xr.baseExperience.enterXRAsync('immersive-vr', 'local-floor')
    },
    dispose() {
      window.removeEventListener('resize', resize)
      navigation.dispose()
      movementSpeed.dispose()
      playerNavigation.dispose()
      contactMask.dispose()
      panel?.dispose()
      painted = clearMarks(painted)
      resources.dispose()
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
