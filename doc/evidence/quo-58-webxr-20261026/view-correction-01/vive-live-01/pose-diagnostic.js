// Temporary observation of calls the application already makes. No extra XR
// frame loop, pose replacement, scene access or input injection. Restore the
// original native method after 360 observed frames, session end or 15 seconds.
const done = arguments[arguments.length - 1]
const session = window.quodAcceptanceSession
if (!session) { done({ error: 'No active native session' }); return }
const prototype = XRFrame.prototype
const descriptor = Object.getOwnPropertyDescriptor(prototype, 'getPose')
const original = descriptor.value
const rows = [], frames = new WeakMap()
let count = 0, completed = false, deadline
function finish(reason) {
  if (completed) return
  completed = true
  clearTimeout(deadline)
  session.removeEventListener('end', ended)
  const stillOwned = prototype.getPose === observe
  if (stillOwned) Object.defineProperty(prototype, 'getPose', descriptor)
  done({ reason, originalMethodRestored: stillOwned, frames: count, rows })
}
const ended = () => finish('session-ended')
function observe(space, reference) {
  const pose = original.call(this, space, reference)
  const source = Array.from(session.inputSources).find(input => input.gripSpace === space)
  if (!source || completed) return pose
  let frame = frames.get(this)
  if (!frame) {
    if (count === 360) { finish('frame-bound'); return pose }
    frame = { index: count++, seen: new Set() }
    frames.set(this, frame)
  }
  if (!frame.seen.has(source)) {
    frame.seen.add(source)
    const p = pose?.transform.position
    rows.push({ frame: frame.index, at: performance.now(), hand: source.handedness,
      position: p ? [p.x, p.y, p.z] : null,
      emulated: pose ? pose.emulatedPosition : null })
  }
  return pose
}
Object.defineProperty(prototype, 'getPose', { ...descriptor, value: observe })
session.addEventListener('end', ended, { once: true })
deadline = setTimeout(() => finish('observation-deadline'), 15000)
