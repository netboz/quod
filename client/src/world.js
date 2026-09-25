// Ontology projections over the existing signed read path. These helpers only
// build ordinary goals; exact references are checked inside the selected scope.
import { binary, compound, atom, renderTerm, variable } from './prolog-term.js'
import { readTerm } from './prolog-read.js'
import { readMarks } from './marks.js'
import { signedGoal } from './signed-client.js'
import { b64url } from './key-provider.js'

const encoder = new TextEncoder()
const decoder = new TextDecoder('utf-8', { fatal: true })
const text = value => binary(encoder.encode(value))

export function anchoredGoal(reference, goal) {
  const ns = text(reference.namespace)
  if (!(reference.anchor instanceof Uint8Array) || reference.anchor.length !== 32) {
    throw new Error('an exact ontology reference is required')
  }
  const guard = compound('current_ontology_identity', [ns, binary(reference.anchor)])
  const selector = compound('ontology_ref', [ns, binary(reference.anchor)])
  return `${renderTerm(selector)} :: (${renderTerm(guard)}, ${renderTerm(goal)}).`
}

export async function readPersonalLobby(identity, agent, mode = 'playing', options = {}) {
  if (!['playing', 'edition'].includes(mode)) throw new Error('unknown presentation')
  const reply = await signedGoal(identity, {
    mode: 'read', agent, goal: 'lobby_reference(Lobby).',
  }, options)
  if (reply.result === 'fail') return null
  const reference = readReference(singleBinding(reply, 'Lobby'))
  const scene = await signedGoal(identity, {
    mode: 'read', agent,
    goal: anchoredGoal(reference, compound('lobby_view', [atom(mode), variable('Scene')])),
  }, options)
  return { reference, marks: readMarks(singleBinding(scene, 'Scene')), height: scene.height }
}

export async function readDeviceMenu(identity, agent, subject, options = {}) {
  const reply = await signedGoal(identity, {
    mode: 'read', agent,
    goal: anchoredGoal({ namespace: subject.ontology, anchor: subject.anchor },
      compound('lobby_menu', [subject.entity, variable('Entries')])),
  }, options)
  const entries = readTerm(singleBinding(reply, 'Entries'))
  if (entries.type !== 'list' || entries.tail !== null) throw new Error('invalid action menu')
  return entries.items.map(entry => {
    const [id, label, action] = args(entry, 'menu_entry', 3)
    const [view] = args(action, 'open_view', 1)
    if (id.type !== 'atom' || view.type !== 'atom' || view.value !== 'proof_console') {
      throw new Error('this client does not support the offered view')
    }
    return { id: id.value, label: textValue(label), view: view.value }
  })
}

export function readReference(binding) {
  const [ns, anchor] = args(readTerm(binding), 'ontology_ref', 2)
  if (anchor.type !== 'binary' || anchor.value.length !== 32) throw new Error('invalid lobby anchor')
  return { namespace: textValue(ns), anchor: anchor.value }
}

export function readAgentReference(binding) {
  const [ns, anchor, instance] = args(readTerm(binding), 'agent_instance_ref', 3)
  if (anchor.type !== 'binary' || anchor.value.length !== 32) throw new Error('invalid agent anchor')
  return { namespace: textValue(ns), anchor: b64url(anchor.value),
           instanceText: `${renderTerm(instance)}.` }
}

export function readProofView(binding) {
  const [title, components] = args(readTerm(binding), 'form', 2)
  if (components.type !== 'list' || components.tail !== null) throw new Error('invalid form')
  const expected = { goal: 'editor', results: 'bindings', run: 'button', next: 'button', accept: 'button', stop: 'button' }
  const labels = { title: textValue(title) }
  for (const component of components.items) {
    if (component.type !== 'compound' || component.args.length !== 2) throw new Error('invalid component')
    const [role, label] = component.args
    if (role.type !== 'atom' || expected[role.value] !== component.functor || Object.hasOwn(labels, role.value)) {
      throw new Error('unknown or repeated form component')
    }
    labels[role.value] = textValue(label)
  }
  if (Object.keys(labels).length !== Object.keys(expected).length + 1) throw new Error('incomplete proof workspace')
  return labels
}

export function singleBinding(reply, name) {
  const committed = reply.result === 'operation_outcome' && reply.status === 'committed' && reply.terminal === true
  if ((reply.result !== 'ok' && !committed) || reply.bindings?.length !== 1 ||
      typeof reply.bindings[0][name] !== 'string') {
    throw new Error(`expected one ${name} answer; received ${reply.result ?? 'no result'}`)
  }
  return reply.bindings[0][name]
}

function textValue(term) {
  if (term.type !== 'binary' || term.value.length === 0) throw new Error('expected text')
  return decoder.decode(term.value)
}

function args(term, name, length) {
  if (term.type !== 'compound' || term.functor !== name || term.args.length !== length) {
    throw new Error(`expected ${name}/${length}`)
  }
  return term.args
}
