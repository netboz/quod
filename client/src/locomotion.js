// Input and presentation over the signed predicate interface. This module
// never predicts collisions or derives a body from rendered geometry.
import { readTerm } from './prolog-read.js'
import { binary, compound, number, variable } from './prolog-term.js'
import { anchoredGoal } from './world.js'
import { fromB64url } from './key-provider.js'

const args = (term, name, count) => {
  if (term?.type !== 'compound' || term.functor !== name || term.args.length !== count) {
    throw new Error(`unsupported movement ${name}`)
  }
  return term.args
}
const integer = (term, min = 0) => {
  if (term?.type !== 'number' || !Number.isSafeInteger(term.value) || term.value < min) {
    throw new Error('unsupported movement number')
  }
  return term.value
}
const identity = term => {
  if (term?.type !== 'number' || !['number', 'bigint'].includes(typeof term.value) ||
      (typeof term.value === 'number' && !Number.isSafeInteger(term.value)) || BigInt(term.value) < 0n) {
    throw new Error('invalid movement identity')
  }
  return String(term.value)
}
const vector = (term, name) => args(term, name, 3).map(n => integer(n, -Number.MAX_SAFE_INTEGER) / 1000)

export function readControl(text) {
  const term = readTerm(text)
  if (term.type === 'atom' && term.value === 'none') return null
  const [, epoch, definition] = args(term, 'control', 3)
  const [agent, revision, body, bodyRevision, motion, view] = args(definition, 'controlled_agent', 6)
  const [mode, speed, turn, lease, , capabilities] = args(motion, 'motion', 6)
  const grounded = mode.type === 'compound' && mode.functor === 'grounded'
  if (grounded) {
    const up = integer(args(mode, 'grounded', 1)[0], 1)
    if (up > 1000) throw new Error('invalid movement support')
  } else if (mode.type !== 'atom' || mode.value !== 'free') throw new Error('unsupported movement mode')
  const [name, pose, tracking] = args(view, 'viewpoint', 3)
  let trackingRadius = null
  if (tracking.type === 'compound' && tracking.functor === 'tracking') {
    const [mapping, radius] = args(tracking, 'tracking', 2)
    if (mapping.type !== 'atom' || mapping.value !== 'view_only') throw new Error('unsupported tracking mapping')
    trackingRadius = integer(radius, 1) / 1000
  } else if (tracking.type !== 'atom' || tracking.value !== 'view_only') throw new Error('unsupported tracking mapping')
  const [position, rotation] = args(pose, 'pose', 2)
  if (capabilities.type !== 'list' || capabilities.tail !== null) throw new Error('invalid movement capabilities')
  let teleport = null, snap = null, jump = null, reposition = false
  for (const capability of capabilities.items) {
    if (capability.functor === 'teleport' && teleport === null) {
      const [reach, drop, up] = args(capability, 'teleport', 3).map(n => integer(n, 1))
      if (up > 1000) throw new Error('invalid landing support')
      teleport = { reach: reach / 1000, drop: drop / 1000, up: up / 1000 }
    } else if (capability.functor === 'snap' && snap === null) {
      snap = integer(args(capability, 'snap', 1)[0], 1)
      if (snap > 3141) throw new Error('unsupported snap turn')
    } else if (capability.functor === 'jump' && jump === null) {
      jump = integer(args(capability, 'jump', 1)[0], 1)
    } else if (capability.type === 'atom' && capability.value === 'reposition' && !reposition) {
      reposition = true
    } else throw new Error('unsupported movement capability')
  }
  return { term, agent, revision: identity(revision), epoch: identity(epoch),
    body: identity(body), bodyRevision: identity(bodyRevision),
    grounded, speed: integer(speed, 1) / 1000, turn: integer(turn, 1) / 1000,
    lease: integer(lease, 1), teleport, snap, jump, reposition,
    viewpoint: { name, position: vector(position, 'vector'), rotation: vector(rotation, 'rotation'), trackingRadius } }
}

export function movementGoal(world, frame, control, sequence, input) {
  const physicsFrame = compound('physics_frame', [readTerm(frame.world), readTerm(frame.authority),
    number(BigInt(frame.epoch)), number(BigInt(frame.generation)), binary(fromB64url(frame.incarnation)),
    number(BigInt(frame.structure))])
  const [, , worldId] = args(readTerm(frame.world), 'world_ref', 3)
  const controlFrame = compound('control_frame', [physicsFrame, binary(fromB64url(frame.registration))])
  return anchoredGoal(world, compound('physics_control_input', [worldId, controlFrame,
    number(BigInt(control.epoch)), number(sequence), input, variable('Result')]))
}

// Quantized zero is an integer; generic Prolog numbers preserve -0 as a float.
const milliUnits = value => number(Math.trunc(value * 1000) + 0)

export function driveInput(velocity, angular = [0, 0, 0]) {
  const measured = values => values.map(value => {
    if (!Number.isFinite(value)) throw new Error('invalid movement input')
    return milliUnits(value)
  })
  if (velocity.length !== 3 || angular.length !== 3) throw new Error('invalid movement vector')
  return compound('drive', [compound('vector', measured(velocity)), compound('angular', measured(angular))])
}

export const snapInput = angle => compound('snap', [number(angle)])
export const jumpInput = speed => compound('jump', [number(speed)])
export const teleportInput = (position, origin = [0n, 0n, 0n]) => {
  if (position.length !== 3 || !position.every(n => Number.isFinite(n) && Number.isSafeInteger(Math.trunc(n * 1000))) ||
      origin.length !== 3 || !origin.every(n => typeof n === 'bigint')) throw new Error('invalid landing')
  return compound('teleport', [compound('vector', position.map((n, axis) =>
    number(BigInt(Math.trunc(n * 1000)) + origin[axis])))])
}

// Stable body identity/revision come from the authoritative projection, never
// a mesh name or a view-scoped mark id. Impulse uses newton seconds.
export function pushInput(body, revision, impulse) {
  const id = BigInt(body), rev = BigInt(revision)
  if (id < 0n || id >= 2n ** 64n || rev <= 0n || rev >= 2n ** 64n ||
      impulse.length !== 3 || !impulse.every(n => Number.isFinite(n) && Number.isSafeInteger(Math.trunc(n * 1000)))) {
    throw new Error('invalid push input')
  }
  return compound('push', [compound('body', [number(id), number(rev)]),
    compound('vector', impulse.map(milliUnits))])
}
