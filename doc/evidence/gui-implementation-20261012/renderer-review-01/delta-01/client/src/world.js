// Ontology projections over the existing signed read path. These helpers only
// build ordinary goals; exact references are checked inside the selected scope.
import { binary, compound, atom, renderTerm, variable, list, number } from './prolog-term.js'
import { readTerm, requireProjection } from './prolog-read.js'
import { signedGoal } from './signed-client.js'
import { b64url, fromB64url } from './key-provider.js'

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

export async function readPersonalLobby(identity, agent, options = {}) {
  const reply = await signedGoal(identity, {
    mode: 'read', agent, goal: 'lobby_navigation(Lobby,Modes).',
  }, options)
  if (reply.result === 'fail') return null
  const [ns, anchor, instance] = args(readTerm(singleBinding(reply, 'Lobby')), 'entity_ref', 3)
  const reference = { namespace: textValue(ns), anchor: anchor.value, instance }
  anchoredGoal(reference, instance)
  const modes = readTerm(singleBinding(reply, 'Modes'))
  if (modes.type !== 'list' || modes.tail !== null || modes.items.some(item => item.type !== 'atom')) {
    throw new Error('invalid lobby eidolons')
  }
  // Keep every navigation dependency, including foreign policy. The next
  // signed view visits and fences this exact set before installing anything.
  const dependencies = reply.dependencies
  viewDependencies(dependencies)
  if (!dependencies.length) throw new Error('missing navigation dependencies')
  return { reference, dependencies, modes: modes.items.map(item => item.value) }
}

export function viewDependencies(dependencies) {
  if (!Array.isArray(dependencies)) throw new Error('missing navigation dependencies')
  let previous = null
  return list(dependencies.map(({ ns, genesis_anchor, height }) => {
    const anchor = fromB64url(genesis_anchor)
    const bytes = encoder.encode(ns)
    const difference = previous?.findIndex((byte, i) => byte !== bytes[i]) ?? -1
    const ordered = !previous || (difference === -1 ? previous.length < bytes.length
      : difference < bytes.length && previous[difference] < bytes[difference])
    if (typeof ns !== 'string' || !ns.length || !ordered ||
        anchor.length !== 32 || typeof height !== 'string' || !/^(0|[1-9][0-9]*)$/.test(height) ||
        BigInt(height) > 18446744073709551615n) throw new Error('invalid navigation dependency')
    previous = bytes
    return compound('dependency', [text(ns), binary(anchor), number(BigInt(height))])
  }))
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
  const root = readTerm(binding)
  requireProjection(root)
  const roles = new Set()
  const contracts = {
    form: ['layout'], container: ['layout'], text_box: ['required', 'readonly', 'max_bytes'],
    selection: ['required', 'readonly', 'options'], slider: ['required', 'readonly', 'range', 'unit'],
    rotary_knob: ['required', 'readonly', 'range', 'unit'], button: [],
    editor: ['readonly'], bindings: [], catalogue_selection: ['readonly'],
  }
  const integer = term => {
    if (term.type !== 'number' || term.literal || !Number.isSafeInteger(term.value)) throw new Error('unsupported GUI integer')
    return term.value
  }
  const decode = term => {
    const [id, kind, properties, children] = args(term, 'component', 4)
    const role = renderTerm(id)
    if (roles.has(role)) throw new Error('repeated component identity')
    roles.add(role)
    if (kind.type !== 'atom' || !Object.hasOwn(contracts, kind.value)) throw new Error('unsupported GUI component')
    if (properties.type !== 'list' || children.type !== 'list') throw new Error('invalid component collections')
    const field = { role, kind: kind.value }
    const seen = new Set()
    for (const property of properties.items) {
      const [key, value] = args(property, 'property', 2)
      if (key.type !== 'atom' || seen.has(key.value)) throw new Error('invalid component property')
      if (!['label', 'help', 'enabled', ...contracts[field.kind]].includes(key.value)) throw new Error('unsupported GUI property for component kind')
      seen.add(key.value)
      switch (key.value) {
        case 'label': field.label = textValue(value); break
        case 'help':
          if (value.type !== 'binary') throw new Error('invalid help text')
          field.help = decoder.decode(value.value); break
        case 'unit':
          if (value.type !== 'atom' && value.type !== 'binary') throw new Error('invalid numeric unit')
          field.unit = value.type === 'atom' ? value.value : decoder.decode(value.value); break
        case 'enabled': case 'readonly': case 'required':
          if (value.type !== 'atom' || !['true', 'false'].includes(value.value)) throw new Error('invalid component flag')
          field[key.value] = value.value === 'true'; break
        case 'layout':
          if (value.type !== 'atom' || !['row', 'column'].includes(value.value)) throw new Error('invalid layout')
          field.layout = value.value; break
        case 'max_bytes':
          field.maxBytes = integer(value)
          if (field.maxBytes < 0) throw new Error('invalid text bound')
          break
        case 'range': {
          const [min, max, step] = args(value, 'range', 3).map(integer)
          if (min > max || step <= 0 || !Number.isSafeInteger(max - min)) throw new Error('invalid numeric range')
          field.range = { min, max, step }; break
        }
        case 'options': {
          if (value.type !== 'list' || !value.items.length) throw new Error('invalid options')
          const ids = new Set()
          field.options = value.items.map(option => {
            const [id, label] = args(option, 'option', 2)
            const value = renderTerm(id)
            if (ids.has(value)) throw new Error('repeated option identity')
            ids.add(value)
            return { value, label: textValue(label) }
          }); break
        }
        default: throw new Error(`unsupported GUI property: ${key.value}`)
      }
    }
    if (!field.label) throw new Error('missing component label')
    if (['slider', 'rotary_knob'].includes(field.kind) && !field.range) throw new Error('missing numeric range')
    if (field.kind === 'selection' && !field.options) throw new Error('missing selection options')
    if (field.kind === 'form' || field.kind === 'container') field.children = children.items.map(decode)
    else if (children.items.length) throw new Error('children on leaf component')
    return field
  }
  const form = decode(root)
  if (form.kind !== 'form') throw new Error('expected a form')
  return { title: form.label, enabled: form.enabled, layout: form.layout, fields: form.children }
}

// Component roles identify a supported capability. Ontologies choose the view
// name and labels; a new form cannot call arbitrary client code through them.
export function formLabels(form, expected) {
  const labels = { title: form.title }
  const leaves = fields => fields.flatMap(field => field.children ? leaves(field.children) : [field])
  for (const field of leaves(form.fields)) {
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

export const codeForm = form => {
  const fields = form.fields
  const readOnly = fields.length === 2 &&
    fields.some(field => field.role === 'predicate' && field.kind === 'catalogue_selection') &&
    fields.some(field => field.role === 'source' && field.kind === 'editor')
  if (readOnly) return { ...formLabels(form, { predicate: 'catalogue_selection', source: 'editor' }), editable: false }
  return { ...formLabels(form, {
    predicate: 'catalogue_selection', new_predicate: 'text_box', source: 'editor', results: 'bindings',
    run: 'button', accept: 'button', stop: 'button', create: 'button', resolve: 'button',
  }), editable: true }
}

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

export class GoalFailure extends Error {
  constructor(reasons = []) {
    const accessDenied = Array.isArray(reasons) && reasons.some(reason => {
      try {
        const term = readTerm(reason)
        return term.type === 'compound' && term.functor === 'not_allowed' && term.args.length === 1
      } catch { return false }
    })
    super(accessDenied ? 'This account is not allowed to make this query.' : 'The query returned no answer.')
    this.name = 'GoalFailure'
    this.accessDenied = accessDenied
    this.reasons = reasons
  }
}

export function singleBinding(reply, name) {
  if (reply.result === 'fail') throw new GoalFailure(reply.reasons)
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
