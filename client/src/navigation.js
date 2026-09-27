// Desktop navigation is a client concern. It changes only the observer's local
// camera; ontology geometry and authoritative world state remain untouched.
export function configureDesktopCamera(camera) {
  camera.speed = 2
  camera.inertia = 0.55
  camera.angularSensibility = 2600
  camera.keysUp = [87, 38]
  camera.keysDown = [83, 40]
  camera.keysLeft = [65, 37]
  camera.keysRight = [68, 39]
}

export function createMovementSpeed(canvas, camera, {
  normal = 2,
  fast = 5,
} = {}) {
  const owner = canvas.ownerDocument
  const view = owner.defaultView
  let disposed = false

  const setSpeed = speed => { if (!disposed) camera.speed = speed }
  const keyDown = event => { if (event.key === 'Shift') setSpeed(fast) }
  const keyUp = event => { if (event.key === 'Shift') setSpeed(normal) }
  const reset = () => setSpeed(normal)

  camera.speed = normal
  owner.addEventListener('keydown', keyDown)
  owner.addEventListener('keyup', keyUp)
  view?.addEventListener('blur', reset)

  return {
    dispose() {
      if (disposed) return
      disposed = true
      camera.speed = normal
      owner.removeEventListener('keydown', keyDown)
      owner.removeEventListener('keyup', keyUp)
      view?.removeEventListener('blur', reset)
    },
  }
}

export function createPointerLock(canvas, {
  onChanged = () => {},
  onError = () => {},
} = {}) {
  const owner = canvas.ownerDocument
  let disposed = false

  const active = () => owner.pointerLockElement === canvas
  const changed = () => { if (!disposed) onChanged(active()) }
  const failed = error => {
    if (!disposed) onError(error instanceof Error ? error : new Error('Pointer capture was refused.'))
  }
  const capture = () => {
    if (disposed || active()) return
    if (typeof canvas.requestPointerLock !== 'function') {
      failed(new Error('Pointer capture is unavailable in this browser.'))
      return
    }
    canvas.focus()
    try {
      const request = canvas.requestPointerLock()
      if (request && typeof request.catch === 'function') request.catch(failed)
    } catch (error) { failed(error) }
  }
  const release = () => {
    if (active() && typeof owner.exitPointerLock === 'function') owner.exitPointerLock()
  }

  canvas.addEventListener('click', capture)
  owner.addEventListener('pointerlockchange', changed)
  owner.addEventListener('pointerlockerror', failed)
  onChanged(active())

  return {
    active,
    capture,
    release,
    dispose() {
      if (disposed) return
      release()
      disposed = true
      canvas.removeEventListener('click', capture)
      owner.removeEventListener('pointerlockchange', changed)
      owner.removeEventListener('pointerlockerror', failed)
    },
  }
}
