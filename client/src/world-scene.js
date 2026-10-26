import { Engine } from '@babylonjs/core/Engines/engine.js'
import { Scene } from '@babylonjs/core/scene.js'
import { UniversalCamera } from '@babylonjs/core/Cameras/universalCamera.js'
import { HemisphericLight } from '@babylonjs/core/Lights/hemisphericLight.js'
import { Vector3 } from '@babylonjs/core/Maths/math.vector.js'
import { Color3, Color4 } from '@babylonjs/core/Maths/math.color.js'
import { Layer } from '@babylonjs/core/Layers/layer.js'
import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder.js'
import { StandardMaterial } from '@babylonjs/core/Materials/standardMaterial.js'
import { DynamicTexture } from '@babylonjs/core/Materials/Textures/dynamicTexture.js'
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js'
// Babylon's modular build registers picking separately from scene rendering.
import '@babylonjs/core/Culling/ray.js'
import { PointerEventTypes } from '@babylonjs/core/Events/pointerEvents.js'
import { PALETTE } from './palette.js'
import { paintMarks, clearMarks, paintBodyPoses, paintTerrain, paintSkies, compareOpaqueMarks } from './scene.js'
import { createRenderResources } from './render-resources.js'
import { createWorkspacePanel } from './workspace-panel.js'
import { configureDesktopCamera, createMovementSpeed, createPointerLock } from './navigation.js'
import { WebXRTrackingState } from '@babylonjs/core/XR/webXRTypes.js'
import { createWorldXR } from './world-xr.js'
import { createControllerScene } from './controller-scene.js'
import { createControlledNavigation } from './controlled-navigation.js'

const MENU_RADIUS = 0.36

// Sector zero starts at the top and proceeds clockwise, matching the visual
// layout. Returning null inside the dead zone lets a user press the pad before
// committing to an action.
export function radialIndex({ x, y }, count, deadZone) {
  if (!Number.isInteger(count) || count < 1 || Math.hypot(x, y) < deadZone) return null
  const sector = 2 * Math.PI / count
  const clockwiseFromTop = (Math.atan2(x, -y) + 2 * Math.PI) % (2 * Math.PI)
  return Math.floor((clockwiseFromTop + sector / 2) / sector) % count
}

// The camera and lighting belong to this viewing session. All visible model
// geometry comes from the ontology projection, including the lobby floor.
export function createWorld(canvas, onPick, onImmersiveChanged = () => {},
  onResourceError = () => {}, onNavigationChanged = () => {}, onControllersChanged = () => {}, onXRStateChanged = () => {}) {
  const engine = new Engine(canvas, true, { stencil: true })
  const scene = new Scene(engine)
  scene.useRightHandedSystem = true
  scene.setRenderingOrder(0, compareOpaqueMarks)
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
  let workspace = null, workspaceSchema = null
  let panel = null
  const appearanceSettings = { opacity: 0.78, scale: 1, distance: 1.6 }
  let immersive = false
  let xr = null, workspaceObserver = null, disposal = null
  const xrLifecycle = createWorldXR(scene, {
    connect(experience) {
      xr = experience
      controllers.connect(experience)
      experience.baseExperience.camera.onTrackingStateChanged.add(xrLifecycle.guard(state => {
        if (state === WebXRTrackingState.TRACKING) {
          // Tracking is announced before the pose update.
          scene.onBeforeRenderObservable.remove(workspaceObserver)
          workspaceObserver = scene.onBeforeRenderObservable.addOnce(xrLifecycle.guard(showWorkspace))
        }
      }))
    },
    disconnect() {
      controllers.disconnect()
      scene.onBeforeRenderObservable.remove(workspaceObserver)
      workspaceObserver = null
      xr = null
    },
    cancel() { navigation.release(); controllers.cancel(); closeMenu() },
    changed(state, experience) {
      const active = state === 'presenting'
      if (active !== immersive) {
        immersive = active
        playerNavigation.xr(immersive ? experience.baseExperience.camera : null)
        closeMenu()
        showWorkspace()
        onImmersiveChanged(immersive)
      }
      onXRStateChanged(state)
    },
    error: onResourceError,
  })
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
  const controllers = createControllerScene(scene, resources, playerNavigation, {
    guard: xrLifecycle.guard,
    workspace: () => workspace ? panel : null, changed: onControllersChanged, error: onResourceError,
    menu: { open: (axes, threshold) => { openMenu(axes, threshold); return Boolean(menu.root) },
      move: (axes, threshold) => selectMenuEntry(menu, radialIndex(axes, menu.entries.length, threshold)),
      cancel: closeMenu,
      commit: () => { const entry = menu.entries[menu.selected]; closeMenu(); if (entry) menu.activate?.(entry) } },
  })
  scene.onBeforeRenderObservable.add(xrLifecycle.guard(() => playerNavigation.render()))
  scene.onPointerObservable.add(xrLifecycle.guard(info => {
    const pick = navigation.active()
      ? scene.pick(engine.getRenderWidth() / 2, engine.getRenderHeight() / 2)
      : info.pickInfo
    let node = pick?.pickedMesh
    if (node?.metadata?.menuEntry) {
      controllers.menuSelected()
      const entry = node.metadata.menuEntry
      closeMenu()
      menu.activate?.(entry)
      return
    }
    while (node && !node.metadata?.depicts) node = node.parent
    if (node?.metadata?.depicts?.anchor) onPick(node.metadata.depicts)
  }), PointerEventTypes.POINTERPICK)
  let painted = new Map()
  let currentMarks = null
  let coordinateFrame = null
  let simulation = null, terrainCamera = null, terrainObserver = null
  scene.onBeforeCameraRenderObservable.add(xrLifecycle.guard(view => paintSkies(painted, view)))

  function cameraInterest() {
    const active = scene.activeCamera
    if (simulation?.selection === 'active' && active) simulation.interest?.(active.globalPosition.asArray())
  }
  function terrainHorizon() {
    const root = simulation?.marks.find(mark => mark.kind === 'terrain')
    const distance = simulation?.selection === 'active' && root ? root.size.viewDistance[0] / 1000 : null
    scene.fogMode = distance === null ? Scene.FOGMODE_NONE : Scene.FOGMODE_LINEAR
    if (distance !== null) {
      const atmosphere = simulation.marks.find(mark => mark.kind === 'sky_sphere')?.material
      scene.fogColor.copyFrom(atmosphere
        ? Color3.FromHexString(atmosphere.colour).toLinearSpace().scale(atmosphere.emission).toGammaSpace() : sky)
      scene.fogStart = distance * 0.75; scene.fogEnd = distance
    }
  }
  function bindTerrainCamera() {
    if (terrainCamera) {
      terrainCamera.onViewMatrixChangedObservable.remove(terrainObserver)
    }
    terrainCamera = scene.activeCamera
    terrainObserver = terrainCamera?.onViewMatrixChangedObservable.add(xrLifecycle.guard(cameraInterest)) ?? null
    terrainHorizon()
    cameraInterest()
  }
  scene.onActiveCameraChanged.add(xrLifecycle.guard(bindTerrainCamera, true))
  bindTerrainCamera()

  function closeMenu() {
    menu.root?.dispose(false, true)
    menu = { ...menu, root: null, items: [], selected: null }
  }


  function openMenu(axes, threshold) {
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
    const initial = radialIndex(axes, count, threshold)
    if (initial !== null) selectMenuEntry(menu, initial)
    else for (const item of items) drawMenuLabel(item.texture, item.entry.label, false)
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
  engine.runRenderLoop(xrLifecycle.guard(() => scene.render()))
  void xrLifecycle.prepare().catch(onResourceError)
  return {
    update(current) {
      if (simulation?.physicalFrame?.registration !== current?.physicalFrame?.registration) controllers.cancel()
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
      const previousBinding = playerNavigation.binding()
      playerNavigation.update(observer ? undefined : current?.selection === 'active' ? current : null)
      if (previousBinding !== playerNavigation.binding()) controllers.cancel()
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
      if (JSON.stringify(menu.entries) === JSON.stringify(entries)) { menu.activate = activate; return }
      controllers.cancelMenu()
      closeMenu()
      menu = { ...menu, entries: [...entries], activate }
    },
    setControllerMapping: controllers.install,
    chooseController: controllers.choose,
    controllerStatus: () => controllers.status,
    setWorkspace(model) {
      const nextSchema = model ? JSON.stringify(model.view) : null
      if (workspaceSchema !== nextSchema) controllers.cancel()
      workspaceSchema = nextSchema
      workspace = model
      if (model) {
        navigation.release()
        closeMenu()
      }
      showWorkspace()
    },
    releaseNavigation() { navigation.release() },
    immersive: xrLifecycle.enter,
    exitImmersive: () => xrLifecycle.exit(),
    dispose() {
      if (disposal) return disposal
      window.removeEventListener('resize', resize)
      navigation.dispose()
      movementSpeed.dispose()
      simulation = null
      workspace = null
      disposal = xrLifecycle.dispose().then(() => {
        controllers.dispose()
        playerNavigation.dispose()
        contactMask.dispose()
        panel?.dispose()
        painted = clearMarks(painted)
        resources.dispose()
        scene.dispose()
        engine.dispose()
      })
      return disposal
    },
  }
}

function drawMenuLabel(texture, label, selected) {
  texture.getContext().clearRect(0, 0, texture.getSize().width, texture.getSize().height)
  texture.drawText(label, null, 122, 'bold 54px system-ui, sans-serif',
                   selected ? PALETTE.navy : '#F5F1EB',
                   selected ? PALETTE.gold : '#243744', true, true)
}

export function selectMenuEntry(menu, index) {
  if (menu.selected === index) return
  if (index !== null && (index < 0 || index >= menu.items.length)) return
  menu.selected = index
  for (let position = 0; position < menu.items.length; position += 1) {
    const { texture, entry } = menu.items[position]
    drawMenuLabel(texture, entry.label, position === index)
  }
}
