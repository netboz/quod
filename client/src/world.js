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
  return `${renderTerm(ns)} :: (${renderTerm(guard)}, ${renderTerm(goal)}).`
}

export async function readPersonalLobby(identity, agent, mode = 'playing', options = {}) {
  const reply = await signedGoal(identity, {
    mode: 'read', agent, goal: 'lobby_reference(Lobby).',
  }, options)
  if (reply.result === 'fail') return null
  const reference = readReference(singleBinding(reply, 'Lobby'))
  const scene = await signedGoal(identity, {
    mode: 'read', agent,
    goal: anchoredGoal(reference, compound(',', [
      compound('lobby_modes', [variable('Modes')]),
      compound('lobby_view', [atom(mode), variable('Scene')]),
    ])),
  }, options)
  const modes = readTerm(singleBinding(scene, 'Modes'))
  if (modes.type !== 'list' || modes.tail !== null || modes.items.some(item => item.type !== 'atom')) {
    throw new Error('invalid lobby eidolons')
  }
  return { reference, marks: readMarks(singleBinding(scene, 'Scene')), height: scene.height,
    modes: modes.items.map(item => item.value) }
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
    if (id.type !== 'atom' || view.type !== 'atom') {
      throw new Error('invalid workspace reference')
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

export function readGuiView(binding) {
  const [title, components] = args(readTerm(binding), 'form', 2)
  if (components.type !== 'list' || components.tail !== null) throw new Error('invalid form')
  const roles = new Set()
  const fields = []
  for (const component of components.items) {
    if (component.type !== 'compound' || component.args.length !== 2) throw new Error('invalid component')
    const [role, label] = component.args
    if (role.type !== 'atom' || roles.has(role.value)) {
      throw new Error('invalid or repeated form role')
    }
    roles.add(role.value)
    fields.push({ kind: component.functor, role: role.value, label: textValue(label) })
  }
  return { title: textValue(title), fields }
}

// Component roles identify a supported capability. Ontologies choose the view
// name and labels; a new form cannot call arbitrary client code through them.
export function formLabels(form, expected) {
  const labels = { title: form.title }
  for (const field of form.fields) {
    if (expected[field.role] !== field.kind) {
      throw new Error(`This client cannot render ${field.kind}(${field.role}).`)
    }
    labels[field.role] = field.label
  }
  if (Object.keys(labels).length !== Object.keys(expected).length + 1) throw new Error('incomplete workspace')
  return labels
}

export const proofForm = form => formLabels(form, {
  goal: 'editor', results: 'bindings', run: 'button', next: 'button', accept: 'button', stop: 'button', resolve: 'button',
})

export const codeForm = form => formLabels(form, {
  predicate: 'choice', new_predicate: 'input', source: 'editor', results: 'bindings',
  run: 'button', accept: 'button', stop: 'button', create: 'button', resolve: 'button',
})

export async function readEntityEidolons(identity, agent, subject, options = {}) {
  const reply = await signedGoal(identity, {
    mode: 'read', agent,
    goal: anchoredGoal({ namespace: subject.ontology, anchor: subject.anchor },
      subject.kind === 'ontology' ? compound('ontology_eidolons', [variable('Choices')])
        : compound('entity_eidolons', [subject.entity, variable('Choices')])),
  }, options)
  const choices = readTerm(singleBinding(reply, 'Choices'))
  if (choices.type !== 'list' || choices.tail !== null) throw new Error('invalid eidolon choices')
  return choices.items.map(choice => {
    const [purpose, style, recipe] = args(choice, 'eidolon', 3)
    const [ns, anchor, name] = args(recipe, 'recipe', 3)
    if (purpose.type !== 'atom' || style.type !== 'atom' || name.type !== 'atom' ||
        anchor.type !== 'binary' || anchor.value.length !== 32) throw new Error('invalid eidolon recipe')
    return { purpose: purpose.value, style: style.value,
      recipe: { namespace: textValue(ns), anchor: anchor.value, name: name.value } }
  })
}

export async function readEidolonWorkspace(identity, agent, subject, choice, options = {}) {
  const target = compound('ontology_ref', [text(subject.ontology), binary(subject.anchor)])
  const reply = await signedGoal(identity, {
    mode: 'read', agent, goal: anchoredGoal(choice.recipe,
      compound('eidolon', [atom(choice.recipe.name), compound('subject', [target, subject.entity]), variable('Workspace')])),
  }, options)
  const [ref, entity, tools, form] = args(readTerm(singleBinding(reply, 'Workspace')), 'workspace', 4)
  const reference = readReference(renderTerm(ref))
  if (reference.namespace !== subject.ontology || b64url(reference.anchor) !== b64url(subject.anchor) ||
      renderTerm(entity) !== renderTerm(subject.entity)) throw new Error('workspace target changed')
  return { target: reference, tools: readReference(renderTerm(tools)), view: readGuiView(renderTerm(form)) }
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
