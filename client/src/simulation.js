import { readMarks } from './marks.js'
import { goalRequestBytes, signedGoal } from './signed-client.js'
import { b64url, fromB64url } from './key-provider.js'
import { anchoredGoal, viewDependencies } from './world.js'
import { atom, compound, variable } from './prolog-term.js'
import { readControl, movementGoal } from './locomotion.js'

const integer = value => typeof value === 'string' && /^(0|[1-9][0-9]*)$/.test(value)
const fence = frame => JSON.stringify([frame.world, frame.authority, frame.epoch,
  frame.generation, frame.incarnation, frame.structure])
const bodyKey = pose => `${pose.body}:${pose.revision}`

function readFrame(frame) {
  if (!frame || frame.schema !== 1 || frame.units !== 'metres_seconds' || frame.space !== 'world' ||
      ![frame.world, frame.authority, frame.incarnation].every(value => typeof value === 'string' && value.length > 0) ||
      ![frame.epoch, frame.generation, frame.structure, frame.tick].every(integer) || !Array.isArray(frame.poses)) {
    throw new Error('invalid simulation frame')
  }
  const poses = new Map()
  for (const pose of frame.poses) {
    if (!integer(pose.body) || !integer(pose.revision) || poses.has(bodyKey(pose)) ||
        !Array.isArray(pose.position) || pose.position.length !== 3 || !pose.position.every(Number.isFinite) ||
        !Array.isArray(pose.rotation) || pose.rotation.length !== 4 || !pose.rotation.every(Number.isFinite) ||
        Math.abs(Math.hypot(...pose.rotation) - 1) > 0.001) throw new Error('invalid body pose')
    poses.set(bodyKey(pose), pose)
  }
  const feedback = frame.control_state ?? null
  if (feedback !== null && (!/^(?:-1|0|[1-9][0-9]*)$/.test(feedback.sequence) ||
      typeof feedback.pending !== 'boolean' || typeof feedback.result !== 'string')) throw new Error('invalid control feedback')
  const clearance = frame.view_clearance ?? null
  if (clearance !== null && (!Number.isFinite(clearance) || clearance < 0)) throw new Error('invalid view clearance')
  return { fence: fence(frame), tick: BigInt(frame.tick), poses, feedback, clearance,
    received: performance.now(), physicalFrame: frame }
}

export function worldProjection(message) {
  const marks = readMarks(message.marks)
  if (typeof message.view !== 'string' || !integer(message.height) || !integer(message.expires_ms)) {
    throw new Error('invalid world projection')
  }
  if (!Number.isSafeInteger(Number(message.expires_ms)) || Number(message.expires_ms) <= Date.now()) {
    throw new Error('World authorization expired.')
  }
  const ordinary = { marks, view: message.view, selection: message.selection, expires: Number(message.expires_ms) }
  if (message.selection !== 'active') {
    if (!['nonphysical', 'disabled', 'denied', 'recovering', 'unavailable'].includes(message.selection) ||
        message.frame !== undefined || message.control !== undefined) throw new Error('invalid world selection')
    return { ...ordinary, poses: new Map(), control: null, feedback: null }
  }
  const current = readFrame(message.frame)
  if (marks.some(mark =>
    mark.body && (!mark.depicts?.anchor ||
    !current.poses.has(`${mark.body.id}:${mark.body.revision}`)))) throw new Error('invalid simulation projection')
  const bodies = new Set(marks.filter(mark => mark.body).map(mark => `${mark.body.id}:${mark.body.revision}`))
  const control = readControl(message.control ?? 'none')
  if (control) {
    if (typeof message.frame.registration !== 'string' || fromB64url(message.frame.registration).length !== 32) {
      throw new Error('invalid control registration')
    }
    bodies.add(`${control.body}:${control.bodyRevision}`)
    if (!current.feedback) throw new Error('missing control feedback')
  } else if (current.feedback) throw new Error('unexpected control feedback')
  if (bodies.size !== current.poses.size) throw new Error('unexpected projected body')
  if ([...bodies].some(key => !current.poses.has(key))) throw new Error('missing controlled body')
  return { ...ordinary, ...current, bodies, control }
}

export function advanceSimulation(current, message) {
  if (!current || current.selection !== 'active' || message.view !== current.view) return current
  const next = readFrame(message.frame)
  if (next.fence !== current.fence || next.tick <= current.tick) return current
  if (next.poses.size !== current.bodies.size || [...next.poses.keys()].some(key => !current.bodies.has(key))) {
    throw new Error('simulation body set changed without a projection')
  }
  return { ...current, ...next }
}

// Each open signs a fresh read. Disconnect and durable gaps discard all motion
// acceptance state. Reconnect is explicit (or follows a browser online event),
// never a readiness polling timer. Expiry refresh is requested by the server.
export function connectWorldView(identity, agent, { projection, frame, unavailable, refused = () => {}, refreshing = () => {} }, options) {
  const world = { ...options.world }
  if (typeof world.anchor === 'string') world.anchor = fromB64url(world.anchor)
  if (!world.instance) throw new Error('an exact space instance is required')
  const goal = anchoredGoal(world, compound('client_world_view', [world.instance, atom(options.mode),
    viewDependencies(options.dependencies), variable('View')]))
  const Socket = options.WebSocket ?? WebSocket
  const url = options.url ?? new URL('/api/simulation', globalThis.location.href)
  if (url instanceof URL) url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:'
  const socket = new Socket(String(url))
  let active = true, opening = 0, expected = null, current = null
  let sequence = -1n, sending = false, commandEpoch = 0, discreteSequence = null
  let expiryTimer = null
  const clearExpiry = () => { clearTimeout(expiryTimer); expiryTimer = null }
  const send = message => socket.send(JSON.stringify(message))
  async function open() {
    const version = ++opening
    clearExpiry()
    current = null
    expected = null
    commandEpoch++
    discreteSequence = null
    try {
      const request = goalRequestBytes(identity, { mode: 'read', agent, goal })
      const signature = new Uint8Array(await identity.provider.sign(request))
      const view = b64url(new Uint8Array(await crypto.subtle.digest('SHA-256', request)))
      if (!active || version !== opening) return
      expected = view
      send({ type: 'open', session_id: identity.session.session_id, request: b64url(request), signature: b64url(signature),
        world_namespace: world.namespace, world_anchor: b64url(world.anchor) })
    } catch (error) { if (active && version === opening) failed(error) }
  }
  const failed = error => { clearExpiry(); commandEpoch++; current = null; unavailable(error.message ?? String(error)) }
  async function command(input) {
    if (!active || !current?.control || sending) return false
    if (Date.now() >= current.expires) { failed(new Error('Simulation authorization expired.')); return false }
    const observed = BigInt(current.feedback.sequence)
    if (discreteSequence !== null) {
      if (observed < discreteSequence || current.feedback.pending) return false
      discreteSequence = null
    }
    sequence = (sequence > observed ? sequence : observed) + 1n
    if (input.functor !== 'drive') discreteSequence = sequence
    const epoch = commandEpoch
    const goal = movementGoal(world, current.physicalFrame, current.control, sequence, input)
    sending = true
    try {
      const reply = await signedGoal(identity, { mode: 'control', agent, goal }, options)
      if (active && epoch === commandEpoch && reply.result !== 'ok') {
        if (reply.result === 'fail') {
          discreteSequence = null
          refused('Movement was refused.', reply.reasons ?? [])
        } else failed(new Error('Movement outcome unavailable. Refresh the simulation to reconnect.'))
      }
      return reply.result === 'ok'
    } catch (error) {
      // Do not retry an uncertain command or continue with fresh commands after
      // losing its acknowledgement. A fresh view recovers the owner's sequence.
      if (active && epoch === commandEpoch) failed(error)
      return false
    } finally { sending = false }
  }
  socket.onopen = open
  socket.onmessage = event => {
    if (!active) return
    try {
      const message = JSON.parse(event.data)
      if (message.type === 'refresh') {
        commandEpoch++
        current = null
        clearExpiry()
        if (refreshing(message.reason) !== false) {
          if (message.reason === 'navigation_changed') failed(new Error('The selected space changed. Reload the view.'))
          else void open()
        }
      } else if (message.type === 'unavailable') {
        clearExpiry()
        commandEpoch++
        current = null
        unavailable(message.reason)
      } else if (message.type === 'projection' && message.view === expected) {
        commandEpoch++
        current = worldProjection(message)
        clearExpiry()
        expiryTimer = setTimeout(() => failed(new Error('Simulation authorization expired.')), Math.max(0, current.expires - Date.now()))
        sequence = current.feedback ? BigInt(current.feedback.sequence) : -1n
        current.command = command
        projection(current)
        if (current.selection === 'active') send({ type: 'ack', view: current.view, tick: String(current.tick) })
      } else if (message.type === 'simulation_frame' && current && message.view === expected) {
        const next = advanceSimulation(current, message)
        if (next !== current) { current = next; frame(current) }
        if (current.selection === 'active') send({ type: 'ack', view: current.view, tick: String(current.tick) })
      }
    } catch (error) { failed(error); socket.close() }
  }
  socket.onclose = () => { if (active) failed(new Error('Simulation disconnected. Refresh to reconnect.')) }
  socket.onerror = () => { if (active) failed(new Error('Simulation connection unavailable.')) }
  return { command, close() { clearExpiry(); active = false; opening++; commandEpoch++; current = null; socket.close() } }
}
