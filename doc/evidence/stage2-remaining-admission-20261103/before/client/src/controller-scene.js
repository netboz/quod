import { Vector3 } from '@babylonjs/core/Maths/math.vector.js'
import { Ray } from '@babylonjs/core/Culling/ray.js'
import { PickingInfo } from '@babylonjs/core/Collisions/pickingInfo.js'
import { MeshBuilder } from '@babylonjs/core/Meshes/meshBuilder.js'
import { WebXRTrackingState } from '@babylonjs/core/XR/webXRTypes.js'
import { createControllerInput } from './controller-input.js'
import { paintMarks, clearMarks } from './scene.js'

// Scene-owned glue only: XRInput retains sources/poses; existing render
// resources retain verified models; the normal scene/GUI owners receive picks.
export function createControllerScene(scene, resources, navigation, { menu, workspace, changed, error, guard = fn => fn }) {
  const visuals = new Map(), pointers = new Map(), observers = []
  let xr = null, session = null
  const ray = controller => {
    const value = new Ray(Vector3.Zero(), Vector3.Forward())
    controller.pointer.computeWorldMatrix(true)
    controller.getWorldPointerRayToRef(value)
    return value
  }
  function appearance(controller, profile) {
    const previous = visuals.get(controller)
    if (previous?.profile === profile) return
    if (!profile) {
      if (previous) {
        previous.profile = null; previous.line.isVisible = false
        for (const { node } of previous.painted.values()) node.setEnabled(false)
      }
      return
    }
    if (!controller.grip) return
    const mark = { id: `controller:${controller.uniqueId}`, kind: 'mesh', size: profile.model,
      parent: null, transform: { x: 0, y: 0, z: 0, rx: 0, ry: 0, rz: 0 }, depicts: null }
    const painted = paintMarks(scene, [mark], previous?.painted, resources, error)
    const entry = painted.get(mark.id)
    entry.node.parent = controller.grip
    // Controller appearances are not domain picking targets or physical bodies.
    void entry.ready.then(() => entry.node.getChildMeshes().forEach(mesh => { mesh.isPickable = false }))
    entry.node.setEnabled(false)
    const line = previous?.line ?? MeshBuilder.CreateLines(`controller-ray:${controller.uniqueId}`, {
      points: [Vector3.Zero(), new Vector3(0, 0, -2)],
    }, scene)
    line.parent = controller.pointer; line.isPickable = false; line.isVisible = false
    visuals.set(controller, { profile, painted, line })
  }
  function retireAppearance(controller) {
    const visual = visuals.get(controller)
    if (visual) { clearMarks(visual.painted); visual.line.dispose(); visuals.delete(controller) }
  }
  const pointer = {
    move(controller, id, context) {
      const pick = scene.pickWithRay(ray(controller), mesh => mesh.isEnabled() && mesh.isVisible && mesh.isPickable &&
        (context === 'menu' ? Boolean(mesh.metadata?.menuEntry) : context === 'workspace' ? Boolean(workspace()?.owns(mesh)) : true))
      pointers.set(id, { controller, pick })
      const visual = visuals.get(controller)
      if (visual) { visual.line.isVisible = true; visual.line.scaling.z = (pick?.hit ? pick.distance : 2) / 2 }
      scene.simulatePointerMove(pick, { pointerId: -id, pointerType: 'xr' })
    },
    down(controller, id) { scene.simulatePointerDown(pointers.get(id)?.pick ?? new PickingInfo(), { pointerId: -id, pointerType: 'xr', button: 0 }) },
    up(controller, id) { scene.simulatePointerUp(pointers.get(id)?.pick ?? new PickingInfo(), { pointerId: -id, pointerType: 'xr', button: 0 }) },
    cancel(id) {
      workspace()?.cancelPointer(-id)
      // Empty picking prevents a scene pick; the GUI capture was cancelled first.
      scene.simulatePointerUp(new PickingInfo(), { pointerId: -id, pointerType: 'xr', button: 0 })
    },
    hide(id) {
      const controller = pointers.get(id)?.controller, visual = visuals.get(controller)
      if (visual) visual.line.isVisible = false
      pointers.delete(id)
    },
  }
  const input = createControllerInput({ navigation: { axes: v => navigation.axes(v), snap: s => navigation.snap(s),
    teleport: (controller, fraction) => navigation.teleport(ray(controller).direction, fraction) },
    pointer, menu, blocked: () => Boolean(workspace()), appearance, retireAppearance, changed, guard })
  function observe(observable, handler, retiring = false) { const token = observable.add(guard(handler, retiring)); observers.push(() => observable.remove(token)) }
  function suspend() {
    input.cancel()
    input.frame(() => false, false)
    for (const visual of visuals.values()) {
      visual.line.isVisible = false
      for (const { node } of visual.painted.values()) node.setEnabled(false)
    }
  }
  const visibilityChanged = guard(() => { if (session?.visibilityState !== 'visible') suspend() })
  function attachSession(next) {
    session?.removeEventListener('visibilitychange', visibilityChanged)
    session = next
    session?.addEventListener('visibilitychange', visibilityChanged)
    visibilityChanged()
  }
  function disconnect() {
    for (const remove of observers.splice(0)) remove()
    attachSession(null)
    input.dispose()
    pointers.clear()
    xr = null
  }
  return {
    install: input.install, cancel: input.cancel, cancelMenu: input.cancelMenu, choose: input.choose, menuSelected: input.menuSelected,
    get status() { return input.status },
    connect(experience) {
      if (xr) throw new Error('Controller input is already attached.')
      xr = experience
      for (const controller of xr.input.controllers) input.add(controller)
      observe(xr.input.onControllerAddedObservable, input.add)
      observe(xr.input.onControllerRemovedObservable, input.remove, true)
      const manager = xr.baseExperience.sessionManager
      observe(manager.onXRSessionInit, attachSession)
      attachSession(manager.session)
      observe(manager.onXRFrameObservable, frame => {
        const active = xr.baseExperience.camera.trackingState === WebXRTrackingState.TRACKING && session?.visibilityState === 'visible'
        if (!active) for (const visual of visuals.values()) for (const { node } of visual.painted.values()) node.setEnabled(false)
        input.frame(controller => {
          const source = controller.inputSource
          const grip = source.gripSpace && frame.getPose(source.gripSpace, manager.referenceSpace)
          const target = frame.getPose(source.targetRaySpace, manager.referenceSpace)
          const visual = visuals.get(controller)
          if (visual) for (const { node } of visual.painted.values()) node.setEnabled(Boolean(visual.profile && active && grip))
          return Boolean(grip && target)
        }, active)
      })
      observe(manager.onXRSessionEnded, () => { suspend(); attachSession(null) }, true)
    },
    disconnect,
    dispose: disconnect,
  }
}
