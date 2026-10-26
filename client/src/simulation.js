import { readMarks } from './marks.js'
import { connectSignedView, readViewIdentity } from './signed-view.js'
import { signedGoal } from './signed-client.js'
import { fromB64url } from './key-provider.js'
import { anchoredGoal, viewDependencies } from './world.js'
import { atom, compound, variable } from './prolog-term.js'
import { readControl, movementGoal } from './locomotion.js'

const integer = value => typeof value === 'string' && /^(0|[1-9][0-9]*)$/.test(value)
const fence = frame => JSON.stringify([frame.world, frame.authority, frame.epoch,
  frame.generation, frame.incarnation, frame.structure])
const bodyKey = pose => `${pose.body}:${pose.revision}`

function readFrame(frame) {
  if (!frame || frame.schema !== 2 || frame.units !== 'metres_seconds' || frame.space !== 'local' ||
      ![frame.world, frame.authority, frame.incarnation].every(value => typeof value === 'string' && value.length > 0) ||
      !integer(frame.origin_seq) || !Array.isArray(frame.origin_mm) || frame.origin_mm.length !== 3 ||
      !frame.origin_mm.every(n => typeof n === 'string' && /^(?:0|-?[1-9][0-9]*)$/.test(n)) ||
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
      typeof feedback.pending !== 'boolean' || typeof feedback.result !== 'string' ||
      !Array.isArray(feedback.origin_mm) || feedback.origin_mm.length !== 3 ||
      !feedback.origin_mm.every(n => typeof n === 'string' && /^(?:0|-?[1-9][0-9]*)$/.test(n)))) throw new Error('invalid control feedback')
  return { origin: frame.origin_mm.map(BigInt), originSeq: BigInt(frame.origin_seq),
    fence: fence(frame), tick: BigInt(frame.tick), poses, feedback,
    received: performance.now(), physicalFrame: frame }
}

export function worldProjection(message) {
  const marks = readMarks(message.marks)
  const ordinary = { marks, ...readViewIdentity(message), selection: message.selection }
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
  if (next.fence !== current.fence || next.originSeq < current.originSeq || next.tick < current.tick ||
      (next.tick === current.tick && next.originSeq === current.originSeq)) return current
  if (next.originSeq === current.originSeq && next.origin.some((n, i) => n !== current.origin[i])) {
    throw new Error('simulation origin changed without a frame sequence')
  }
  if (next.poses.size !== current.bodies.size || [...next.poses.keys()].some(key => !current.bodies.has(key))) {
    throw new Error('simulation body set changed without a projection')
  }
  return { ...current, ...next }
}

export function connectWorldView(identity, agent, { projection, frame, unavailable, refused = () => {}, refreshing = () => {} }, options) {
  const world = { ...options.world }
  if (typeof world.anchor === 'string') world.anchor = fromB64url(world.anchor)
  if (!world.instance) throw new Error('an exact space instance is required')
  const goal = anchoredGoal(world, compound('client_world_view', [world.instance, atom(options.mode),
    viewDependencies(options.dependencies), variable('View')]))
  const terrain = terrainDelivery(frame)
  let sequence = -1n, sending = false, commandEpoch = 0, discreteSequence = null
  const stream = connectSignedView(identity, agent, world, 'world', goal, {
    decode: message => terrain.project(worldProjection(message)),
    message: terrain.message, close: terrain.close, frameType: 'simulation_frame', advance: (current, message) => terrain.advance(advanceSimulation(current, message)),
    credit: current => current.selection === 'active'
      ? { type: 'ack', view: current.view, tick: String(current.tick), origin_seq: String(current.originSeq) } : null,
  }, {
    projection(current) {
      const observed = current.feedback ? BigInt(current.feedback.sequence) : -1n
      sequence = sequence > observed ? sequence : observed
      current.command = command
      current.interest = position => terrain.interest(position, message => stream.send(message), stream.fail)
      return projection(current)
    },
    frame, unavailable,
    discard() { terrain.discard(); commandEpoch++; discreteSequence = null },
    refreshing(reason) {
      if (refreshing(reason) === false) return false
      if (reason === 'navigation_changed') {
        stream.fail(new Error('The selected space changed. Reload the view.'))
        return false
      }
    },
  }, options)
  async function command(input) {
    const current = stream.current
    if (!stream.active || !current?.control || current.terrainReady === false || sending) return false
    if (Date.now() >= current.expires) { stream.fail(new Error('Simulation authorization expired.')); return false }
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
      if (stream.active && epoch === commandEpoch && reply.result !== 'ok') {
        if (reply.result === 'fail') {
          discreteSequence = null
          refused('Movement was refused.', reply.reasons ?? [])
        } else stream.fail(new Error('Movement outcome unavailable. Refresh the simulation to reconnect.'))
      }
      return reply.result === 'ok'
    } catch (error) {
      // Do not retry an uncertain command or continue with fresh commands after
      // losing its acknowledgement. A fresh view recovers the owner's sequence.
      if (stream.active && epoch === commandEpoch) stream.fail(error)
      return false
    } finally { sending = false }
  }
  return { command, close: stream.close }
}


// The connection retains verified bytes only for its current manifest. Geometry
// leases and engine instances remain owned by the ordinary scene reconciler.
function terrainDelivery(render) {
  let current = null, token = null, rows = [], retained = new Map(), epoch = 0
  let centre = null, interest = 0n, manifestInterest = 0n
  const key = row => `${row.body}:${row.chunk.join(',')}`
  const signed = value => typeof value === 'string' && /^(?:0|-?[1-9][0-9]*)$/.test(value)
  const require = (ok, reason) => { if (!ok) throw new Error(`Invalid terrain: ${reason}`) }
  const discard = () => { epoch++; current = null; token = null; rows = []; centre = null; interest = 0n; manifestInterest = 0n }
  function project(view) {
    const terrainMarks = value => JSON.stringify(value?.marks.filter(mark => mark.kind === 'terrain'),
      (_, item) => typeof item === 'bigint' ? `${item}n` : item)
    const continuous = current?.selection === 'active' && view.selection === 'active' &&
      Date.now() < current.expires && current.fence === view.fence &&
      terrainMarks(current) === terrainMarks(view)
    discard(); current = view
    const bindings = new Set(view.marks.filter(mark => mark.kind === 'terrain')
      .map(mark => mark.body.id))
    retained = new Map([...retained].filter(([, row]) => bindings.has(row.body)))
    // Keep dormant model leases until the replacement manifest confirms or
    // retires them. An authored body revision alone does not change all chunks.
    view.terrain = continuous ? retained : null
    view.terrainReady = !view.marks.some(mark => mark.kind === 'terrain')
    return view
  }
  async function handle(message, view, send) {
    const version = epoch
    const live = () => current === view && version === epoch && Date.now() < view.expires
    if (message.type === 'terrain_manifest') {
      require(typeof message.token === 'string' && fromB64url(message.token).length === 32, 'token')
      require(integer(message.interest_seq) && BigInt(message.interest_seq) <= interest, 'interest sequence')
      const roots = view.marks.filter(mark => mark.kind === 'terrain')
      const bindings = new Set(roots.map(mark => `${mark.body.id}:${mark.body.revision}`))
      require(Array.isArray(message.chunks) && roots.length > 0, 'manifest')
      const totals = new Map(), keys = new Set()
      for (const [index, row] of message.chunks.entries()) {
        require(row.index === index && bindings.has(`${row.body}:${row.revision}`), 'body binding')
        require(Array.isArray(row.chunk) && row.chunk.length === 3 && row.chunk.every(signed) &&
          Array.isArray(row.origin_mm) && row.origin_mm.length === 3 && row.origin_mm.every(signed), 'coordinates')
        require(Number.isSafeInteger(row.spacing_mm) && row.spacing_mm >= 256 && row.spacing_mm % 2 === 0 &&
          row.spacing_mm * 8 <= 0xffffffff, 'spacing')
        require(row.origin_mm.every((n, k) => BigInt(n) === BigInt(row.chunk[k]) * BigInt(row.spacing_mm) * 8n &&
          Number.isSafeInteger(Number(BigInt(n) - view.origin[k]))), 'origin')
        require(typeof row.digest === 'string' && /^[0-9a-f]{64}$/.test(row.digest), 'digest')
        require(Array.isArray(row.costs) && row.costs.length === 5 &&
          row.costs.every(n => Number.isSafeInteger(n) && n >= 0) && row.costs[4] === 1 &&
          row.costs[0] === 16 + 38 * row.costs[3] && row.costs[1] === 108 * row.costs[3] &&
          row.costs[2] === 3 * row.costs[3] && row.costs[3] <= 6144, 'allocation')
        require(!keys.has(key(row)), 'duplicate chunk'); keys.add(key(row))
        const body = `${row.body}:${row.revision}`, previous = totals.get(body) ?? [0, 0, 0, 0, 0]
        const total = row.costs.map((n, i) => n + previous[i])
        require(total.every(Number.isSafeInteger), 'aggregate overflow'); totals.set(body, total)
      }
      for (const root of roots) {
        const total = totals.get(`${root.body.id}:${root.body.revision}`) ?? [0, 0, 0, 0, 0]
        require(total.every((n, i) => n <= [...root.size.allowed, root.size.chunks][i]), 'aggregate allowance')
      }
      token = message.token; rows = message.chunks; manifestInterest = BigInt(message.interest_seq)
      if (manifestInterest !== interest) {
        send({ type: 'terrain_ack', view: view.view, token, want: [] }); return
      }
      view.terrainReady = false
      const next = new Map(), want = []
      for (const row of rows) {
        const old = retained.get(key(row))
        if (old?.digest === row.digest && old.spacing_mm === row.spacing_mm &&
            old.costs.every((n, i) => n === row.costs[i])) next.set(key(row), { ...row, payload: old.payload })
        else want.push(row.index)
      }
      retained = next; view.terrain = retained
      // Reclaim obsolete renderer leases before accepting another allocation.
      await render(view)
      if (live()) send({ type: 'terrain_ack', view: view.view, token, want })
    } else if (message.token === token) {
      require(Array.isArray(message.chunks) && typeof message.complete === 'boolean' &&
        (message.complete || message.chunks.length > 0) &&
        message.chunks.every(chunk => Number.isSafeInteger(chunk.index) && chunk.index >= 0), 'content batch')
      const acknowledgement = message.complete ? { complete: true } : { through: message.chunks.at(-1).index }
      // Superseded interest releases only this token's delivery credit. It
      // cannot install geometry or announce completion for the newer camera.
      if (manifestInterest !== interest) {
        send({ type: 'terrain_ack', view: view.view, token, ...acknowledgement })
        return
      }
      const missing = rows.filter(row => !retained.has(key(row)))
      require(message.chunks.length <= missing.length &&
        message.complete === (message.chunks.length === missing.length) &&
        message.chunks.every((chunk, i) => chunk.index === missing[i].index), 'requested chunks')
      const verified = []
      for (const [i, chunk] of message.chunks.entries()) {
        const row = missing[i]
        require(typeof chunk.payload === 'string' && chunk.payload.length <= Math.ceil(row.costs[0] * 4 / 3), 'encoded length')
        const payload = fromB64url(chunk.payload)
        require(payload.length === row.costs[0], 'payload length')
        const digest = [...new Uint8Array(await crypto.subtle.digest('SHA-256', payload))]
          .map(n => n.toString(16).padStart(2, '0')).join('')
        if (!live()) return
        if (manifestInterest !== interest) {
          send({ type: 'terrain_ack', view: view.view, token, ...acknowledgement }); return
        }
        require(digest === row.digest, 'content digest')
        const header = new DataView(payload.buffer, payload.byteOffset, payload.byteLength)
        require(header.getUint32(0) === 0x51565431 && header.getUint32(4) === row.spacing_mm &&
          header.getUint32(8) === row.costs[3], 'content metadata')
        verified.push({ ...row, payload })
      }
      for (const row of verified) retained.set(key(row), row)
      view.terrain = retained
      await render(view)
      if (!live()) return
      if (message.complete && manifestInterest === interest) {
        view.terrainReady = true
        await render(view)
      }
      if (live()) send({ type: 'terrain_ack', view: view.view, token, ...acknowledgement })
    }
  }
  return { project, discard,
    interest(position, send, fail) {
      const view = current, root = view?.marks.find(mark => mark.kind === 'terrain')
      if (!root || view.selection !== 'active' || Date.now() >= view.expires) return false
      if (!Array.isArray(position) || position.length !== 3 || !position.every(n => Number.isFinite(n) && Number.isSafeInteger(Math.round(n * 1000)))) return false
      const next = position.map((n, i) => view.origin[i] + BigInt(Math.round(n * 1000)))
      const margin = BigInt(root.size.viewDistance[1])
      if (centre && next.every((n, i) => n - centre[i] < margin && centre[i] - n < margin)) return false
      const sequence = interest + 1n
      if (sequence >= 2n ** 64n) { fail(new Error('Terrain view sequence exhausted.')); return false }
      if (!send({ type: 'terrain_interest', view: view.view, sequence: String(sequence), centre_mm: next.map(String) })) return false
      centre = next; interest = sequence; view.terrainReady = false
      Promise.resolve().then(() => { if (current === view) return render(view) })
        .catch(error => { if (current === view) fail(error) })
      return true
    },
    advance(view) { current = view; return view },
    close() { discard(); retained.clear() },
    message(message, view, send, fail) {
      if (!['terrain_manifest', 'terrain_chunks'].includes(message.type)) return false
      if (!view || view !== current || view.selection !== 'active' || message.view !== view.view) return true
      const version = epoch
      void handle(message, view, send).catch(error => { if (version === epoch && view === current) fail(error) })
      return true
    },
  }
}
