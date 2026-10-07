import { readMarks } from './marks.js'
import { goalRequestBytes } from './signed-client.js'
import { b64url } from './key-provider.js'

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
  return { fence: fence(frame), tick: BigInt(frame.tick), poses }
}

export function simulationProjection(message) {
  const current = readFrame(message.frame)
  const marks = readMarks(message.marks)
  if (typeof message.view !== 'string' || !integer(message.height) || marks.some(mark =>
    !mark.body || mark.parent !== null || !mark.depicts?.anchor ||
    !current.poses.has(`${mark.body.id}:${mark.body.revision}`))) throw new Error('invalid simulation projection')
  const bodies = new Set(marks.map(mark => `${mark.body.id}:${mark.body.revision}`))
  if (bodies.size !== current.poses.size) throw new Error('unexpected projected body')
  return { ...current, marks, view: message.view, bodies }
}

export function advanceSimulation(current, message) {
  if (!current || message.view !== current.view) return current
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
export function connectSimulation(identity, agent, { projection, frame, unavailable, refreshing = () => {} }, options = {}) {
  const Socket = options.WebSocket ?? WebSocket
  const url = options.url ?? new URL('/api/simulation', globalThis.location.href)
  if (url instanceof URL) url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:'
  const socket = new Socket(String(url))
  let active = true, opening = 0, expected = null, current = null
  const send = message => socket.send(JSON.stringify(message))
  async function open() {
    const version = ++opening
    current = null
    expected = null
    try {
      const request = goalRequestBytes(identity, { mode: 'read', agent, goal: 'physics_client_view(View).' })
      const signature = new Uint8Array(await identity.provider.sign(request))
      const view = b64url(new Uint8Array(await crypto.subtle.digest('SHA-256', request)))
      if (!active || version !== opening) return
      expected = view
      send({ type: 'open', session_id: identity.session.session_id, request: b64url(request), signature: b64url(signature) })
    } catch (error) { if (active && version === opening) failed(error) }
  }
  const failed = error => { current = null; unavailable(error.message ?? String(error)) }
  socket.onopen = open
  socket.onmessage = event => {
    if (!active) return
    try {
      const message = JSON.parse(event.data)
      if (message.type === 'refresh') {
        current = null
        refreshing()
        void open()
      } else if (message.type === 'unavailable') {
        current = null
        unavailable(message.reason)
      } else if (message.type === 'projection' && message.view === expected) {
        current = simulationProjection(message)
        projection(current)
        send({ type: 'ack', view: current.view, tick: String(current.tick) })
      } else if (message.type === 'simulation_frame' && current && message.view === expected) {
        const next = advanceSimulation(current, message)
        if (next !== current) { current = next; frame(current) }
        send({ type: 'ack', view: current.view, tick: String(current.tick) })
      }
    } catch (error) { failed(error); socket.close() }
  }
  socket.onclose = () => { if (active) failed(new Error('Simulation disconnected. Refresh to reconnect.')) }
  socket.onerror = () => { if (active) failed(new Error('Simulation connection unavailable.')) }
  return { close() { active = false; opening++; current = null; socket.close() } }
}
