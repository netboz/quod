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
  if (next.fence !== current.fence || next.tick <= current.tick) return current
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
  let sequence = -1n, sending = false, commandEpoch = 0, discreteSequence = null
  const stream = connectSignedView(identity, agent, world, 'world', goal, {
    decode: worldProjection, frameType: 'simulation_frame', advance: advanceSimulation,
    credit: current => current.selection === 'active'
      ? { type: 'ack', view: current.view, tick: String(current.tick) } : null,
  }, {
    projection(current) {
      const observed = current.feedback ? BigInt(current.feedback.sequence) : -1n
      sequence = sequence > observed ? sequence : observed
      current.command = command
      projection(current)
    },
    frame, unavailable,
    discard() { commandEpoch++; discreteSequence = null },
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
    if (!stream.active || !current?.control || sending) return false
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
