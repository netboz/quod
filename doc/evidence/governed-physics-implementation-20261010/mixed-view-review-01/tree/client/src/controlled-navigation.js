import { Quaternion, Vector3 } from '@babylonjs/core/Maths/math.vector.js'
import { TransformNode } from '@babylonjs/core/Meshes/transformNode.js'
import { WebXRTrackingState } from '@babylonjs/core/XR/webXRTypes.js'
import { driveInput, snapInput, teleportInput } from './locomotion.js'

export function authoredRotation([x, y, z]) {
  return Quaternion.RotationAxis(Vector3.Forward(), z)
    .multiply(Quaternion.RotationAxis(Vector3.Up(), y))
    .multiply(Quaternion.RotationAxis(Vector3.Right(), x))
}

// One camera rig follows the accepted physical pose. The XR reference space
// remains device-owned; calibration maps it into the authored camera mount.
export function createControlledNavigation(scene, camera, canvas, {
  active = () => false, blocked = () => false, mask = () => {}, feedback = () => {},
} = {}) {
  const mount = new TransformNode('physical-viewpoint', scene)
  const trackingOrigin = new TransformNode('tracked-view-origin', scene)
  trackingOrigin.parent = mount
  let current, key = null, xrCamera = null, calibrated = false
  let axes = { x: 0, y: 0 }, lastDrive = '', lastSent = -Infinity, lastFeedback = ''
  const held = new Set()
  let observerInputs = []
  const saved = { position: camera.position.clone(), rotation: camera.rotation.clone(), parent: camera.parent,
    inertia: camera.inertia, keys: ['keysUp', 'keysDown', 'keysLeft', 'keysRight'].map(k => [...camera[k]]) }
  const owner = canvas.ownerDocument
  const down = event => {
    if (current === undefined || !active() || blocked() || event.ctrlKey || event.metaKey || event.altKey) return
    if (['w', 'z', 's', 'a', 'q', 'd', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight'].includes(event.key)) {
      held.add(event.key); event.preventDefault()
    }
  }
  const up = event => held.delete(event.key)
  const reset = () => { held.clear(); axes = { x: 0, y: 0 }; lastDrive = '' }
  owner.addEventListener('keydown', down)
  owner.addEventListener('keyup', up)
  owner.defaultView?.addEventListener('blur', reset)
  owner.addEventListener('pointerlockchange', reset)

  function update(value) {
    const wasObserver = current === undefined
    current = value
    if (value === undefined) {
      for (const input of observerInputs) camera.inputs.add(input)
      observerInputs = []
      camera.parent = saved.parent
      camera.position.copyFrom(saved.position)
      camera.rotation.copyFrom(saved.rotation)
      camera.inertia = saved.inertia
      ;['keysUp', 'keysDown', 'keysLeft', 'keysRight'].forEach((k, i) => { camera[k] = [...saved.keys[i]] })
      mask(false); key = null; calibrated = false; reset()
      if (xrCamera) xrCamera.parent = null
      return
    }
    // Entering a physical view disables direct camera translation even while
    // unavailable, unbound or unsupported. It never falls back to flying.
    if (wasObserver) {
      saved.position.copyFrom(camera.position); saved.rotation.copyFrom(camera.rotation)
      saved.parent = camera.parent
      observerInputs = Object.entries(camera.inputs.attached).filter(([name]) => name !== 'mouse').map(([, input]) => input)
      for (const input of observerInputs) camera.inputs.remove(input)
    }
    camera.keysUp = []; camera.keysDown = []; camera.keysLeft = []; camera.keysRight = []
    camera.cameraDirection.setAll(0); camera.inertia = 0
    // A view renewal pauses input but does not recenter a human's headset.
    // Only a changed run, binding, body or authored mount resets calibration.
    if (value === null) { reset(); return }
    const run = value.physicalFrame
    const nextKey = value?.control ? JSON.stringify([run?.world, run?.authority, run?.epoch,
      run?.generation, run?.incarnation, value.control.epoch, value.control.revision,
      value.control.body, value.control.bodyRevision, value.control.viewpoint]) : null
    if (key !== nextKey) {
      key = nextKey; calibrated = false; reset()
      camera.rotation.setAll(0)
    }
    if (!value?.control) return
    camera.parent = mount; camera.position.setAll(0)
    const pose = value.poses.get(`${value.control.body}:${value.control.bodyRevision}`)
    const bodyRotation = Quaternion.FromArray(pose.rotation)
    const localPosition = Vector3.FromArray(value.control.viewpoint.position)
    localPosition.rotateByQuaternionToRef(bodyRotation, mount.position)
    mount.position.addInPlace(Vector3.FromArray(pose.position))
    mount.rotationQuaternion = bodyRotation.multiply(authoredRotation(value.control.viewpoint.rotation))
    const state = value.feedback?.result ?? 'idle'
    // Contact feedback is independent of whether a body pose changed.
    const kind = state.split('(')[0]
    const status = `${value.feedback?.sequence}:${kind}`
    if (status !== lastFeedback) {
      lastFeedback = status
      if (['occupied', 'blocked', 'no_support', 'unsupported', 'exhausted', 'unavailable', 'invalid'].includes(kind)) {
        feedback(kind === 'no_support' ? 'No supported landing there.' : 'Movement blocked by the physical world.')
      }
    }
  }

  function render(now = performance.now()) {
    if (current === undefined) return
    const control = current?.control
    if (xrCamera) {
      if (!control || control.viewpoint.trackingRadius === null || current.clearance === null) {
        mask(true, !control ? 'Physical world unavailable. Movement is paused.'
          : control.viewpoint.trackingRadius === null ? 'This viewpoint has no VR tracking mapping.'
          : 'Physical view unavailable. Movement is paused.'); return
      }
      if (xrCamera.trackingState !== undefined && xrCamera.trackingState !== WebXRTrackingState.TRACKING) {
        mask(true, 'Headset tracking lost. Movement is paused.'); reset(); return
      }
      if (!calibrated) {
        // Recenter heading while preserving tracked pitch and roll. Tilting
        // the head during entry must not tilt the authored reference frame.
        const heading = Vector3.Forward().rotateByQuaternionToRef(xrCamera.rotationQuaternion, new Vector3())
        const inverse = Quaternion.RotationAxis(Vector3.Up(), -Math.atan2(heading.x, heading.z))
        trackingOrigin.rotationQuaternion = inverse
        xrCamera.position.negate().rotateByQuaternionToRef(inverse, trackingOrigin.position)
        calibrated = true
      }
      xrCamera.parent = trackingOrigin
      for (const eye of xrCamera.rigCameras) eye.parent = trackingOrigin
      trackingOrigin.computeWorldMatrix(true)
      const eyes = xrCamera.rigCameras.length ? xrCamera.rigCameras : [xrCamera]
      const distance = Math.max(...eyes.map(eye => {
        const point = eye.position.clone()
        point.rotateByQuaternionToRef(trackingOrigin.rotationQuaternion, point)
        return point.addInPlace(trackingOrigin.position).length()
      }))
      mask(distance > Math.min(current.clearance, control.viewpoint.trackingRadius),
        'View blocked. Return your head toward your starting position.')
    } else mask(false)
    if (!control || !current.command) return
    const enabled = !blocked() && (xrCamera !== null || active())
    const pressed = (...keys) => keys.some(k => held.has(k)) ? 1 : 0
    const forward = enabled ? (xrCamera ? -axes.y : pressed('w', 'z', 'ArrowUp') - pressed('s', 'ArrowDown')) : 0
    const side = enabled ? (xrCamera ? axes.x : pressed('d', 'ArrowRight') - pressed('a', 'q', 'ArrowLeft')) : 0
    const view = xrCamera ?? camera
    const direction = view.getForwardRay().direction.clone()
    if (control.grounded) direction.y = 0
    direction.normalize()
    const right = Vector3.Cross(direction, Vector3.Up()).normalize()
    const velocity = direction.scale(forward).addInPlace(right.scale(side))
    if (velocity.length() > 1) velocity.normalize()
    velocity.scaleInPlace(control.speed)
    const input = driveInput(velocity.asArray())
    const serialized = JSON.stringify(input)
    if (serialized !== lastDrive || (velocity.lengthSquared() > 0 && now - lastSent >= control.lease / 2)) {
      lastDrive = serialized; lastSent = now
      void current.command(input).then(accepted => { if (!accepted) lastDrive = '' })
    }
  }

  return {
    update, render,
    controlled: () => current !== undefined,
    xr(cameraOrNull) {
      if (xrCamera && !cameraOrNull) {
        xrCamera.parent = null
        for (const eye of xrCamera.rigCameras) eye.parent = null
      }
      xrCamera = cameraOrNull; calibrated = false; reset()
      if (!xrCamera) {
        // Babylon copies the last headset position into the desktop camera on
        // XR exit. A controlled desktop view still belongs at its own mount.
        if (current?.control) camera.position.setAll(0)
        mask(false)
      }
    },
    axes(value) { axes = value },
    snap(sign) {
      if (!blocked() && current?.control?.snap && current.command) {
        reset(); void current.command(snapInput(Math.sign(sign) * current.control.snap))
      }
    },
    teleport(direction, fraction = 0.5) {
      const control = current?.control
      if (blocked() || !control?.grounded || !control.teleport || !current.command) return
      const body = current.poses.get(`${control.body}:${control.bodyRevision}`)
      const ray = direction.clone(); ray.y = 0; ray.normalize()
      // The controller selects a body-origin target and the physics predicate
      // checks the complete straight path and downward landing. No mesh pick
      // grants permission. Half-range is the default gesture, not a world cap.
      const target = Vector3.FromArray(body.position).addInPlace(ray.scale(control.teleport.reach * fraction))
      reset(); void current.command(teleportInput(target.asArray()))
    },
    dispose() {
      update(undefined)
      owner.removeEventListener('keydown', down); owner.removeEventListener('keyup', up)
      owner.defaultView?.removeEventListener('blur', reset)
      owner.removeEventListener('pointerlockchange', reset)
      trackingOrigin.dispose(); mount.dispose()
    },
  }
}
