// Ontology projections over the existing signed read path. These helpers only
// build ordinary goals; exact references are checked inside the selected scope.
import { binary, compound, atom, renderTerm, variable, list, number } from './prolog-term.js'
import { readTerm, readList, requireProjection } from './prolog-read.js'
import { signedGoal } from './signed-client.js'
import { numericControlRange, numericDraft, textFeedback, guiValueKind, choiceValues, guiContainer, guiDisplay } from './gui-values.js'
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
    container: ['layout'], display: [], button: [],
    text: ['required', 'readonly', 'max_bytes'], number: ['required', 'readonly', 'range', 'unit'],
    boolean: ['required', 'readonly'], choice: ['required', 'readonly', 'options'],
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
    const family = kind.type === 'atom' ? guiValueKind(kind.value) ??
      (guiContainer(kind.value) ? 'container' : guiDisplay(kind.value) ? 'display' : null) : null
    if (kind.type !== 'atom' || (!family && !['button', 'editor', 'bindings', 'catalogue_selection'].includes(kind.value))) throw new Error('unsupported GUI component')
    if (properties.type !== 'list' || children.type !== 'list') throw new Error('invalid component collections')
    const field = { role, kind: kind.value }
    const seen = new Set()
    for (const property of properties.items) {
      const [key, value] = args(property, 'property', 2)
      if (key.type !== 'atom' || seen.has(key.value)) throw new Error('invalid component property')
      if (!['label', 'help', 'enabled', ...contracts[family ?? field.kind], ...({ selectable_list: ['multiple'], grid: ['columns'], scroll: ['visible_rows'], progress: ['percent'] }[field.kind] ?? [])].includes(key.value)) throw new Error('unsupported GUI property for component kind')
      seen.add(key.value)
      switch (key.value) {
        case 'label': field.label = textValue(value); break
        case 'help':
          if (value.type !== 'binary') throw new Error('invalid help text')
          field.help = decoder.decode(value.value); break
        case 'unit':
          if (value.type !== 'atom' && value.type !== 'binary') throw new Error('invalid numeric unit')
          field.unit = value.type === 'atom' ? value.value : decoder.decode(value.value); break
        case 'enabled': case 'readonly': case 'required': case 'multiple':
          if (value.type !== 'atom' || !['true', 'false'].includes(value.value)) throw new Error('invalid component flag')
          field[key.value] = value.value === 'true'; break
        case 'layout':
          if (value.type !== 'atom' || !['row', 'column', 'grid'].includes(value.value)) throw new Error('invalid layout')
          field.layout = value.value; break
        case 'columns': case 'visible_rows':
          field[key.value === 'visible_rows' ? 'visibleRows' : key.value] = integer(value)
          if (integer(value) <= 0) throw new Error('invalid layout extent')
          break
        case 'percent':
          field.percent = integer(value)
          if (field.percent < 0 || field.percent > 100) throw new Error('invalid progress')
          break
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
    if (guiValueKind(field.kind) === 'number' && !field.range) throw new Error('missing numeric range')
    if (family === 'choice' && !field.options) throw new Error('missing selection options')
    if (field.kind === 'progress' && field.percent === undefined) throw new Error('missing progress')
    if (guiContainer(field.kind)) field.children = children.items.map(decode)
    else if (children.items.length) throw new Error('children on leaf component')
    return field
  }
  const form = decode(root)
  if (form.kind !== 'form') throw new Error('expected a form')
  return { title: form.label, enabled: form.enabled, layout: form.layout, fields: form.children }
}

// Discovery is scoped by the authenticated human's ontology. References carry
// identity only; fields and status are always read from the responsible scope.
export function readGuiQuestionReferences(binding) {
  const seen = new Set()
  return readList(binding).map(term => {
    const [ns, anchor, question] = args(term, 'question_ref', 3)
    if (ns.type !== 'binary' || !ns.value.length || anchor.type !== 'binary' || anchor.value.length !== 32) {
      throw new Error('invalid question reference')
    }
    const key = renderTerm(term)
    if (seen.has(key)) throw new Error('duplicate question reference')
    seen.add(key)
    return { namespace: textValue(ns), anchor: anchor.value, question }
  })
}

export async function readGuiQuestionStatus(identity, agent, reference, options = {}) {
  const reply = await signedGoal(identity, { mode: 'read', agent,
    goal: anchoredGoal(reference, compound('gui_question_status', [reference.question, variable('Status')])),
  }, options)
  const status = readTerm(singleBinding(reply, 'Status'))
  if (status.type !== 'atom' || !['awaiting', 'committed', 'rejected', 'aborted', 'expired'].includes(status.value)) {
    throw new Error('invalid question outcome')
  }
  return status.value
}

// Convert local drafts to ordinary field data. No callback or executable term
// comes from a draft. Both renderers use the same presentation checks; the
// source ontology rechecks its current schema and policy on submission.
export function guiQuestionSubmission(reference, form, draft) {
  if (form.interaction !== 'editable' || form.view.enabled === false) throw new Error('This question is not editable.')
  const leaves = nodes => nodes.flatMap(node => node.children ? leaves(node.children) : [node])
  const inputs = leaves(form.view.fields).filter(field => guiValueKind(field.kind))
  if (Object.keys(draft).length !== inputs.length || inputs.some(field => !Object.hasOwn(draft, field.role))) {
    throw new Error('Incomplete question fields.')
  }
  const fields = inputs.map(field => {
    const value = draft[field.role]
    if (typeof value !== 'string') throw new Error('Invalid question draft.')
    let parsed
    if (guiValueKind(field.kind) === 'text') {
      const error = textFeedback(field, value)
      if (error) throw new Error(error)
      parsed = text(value)
    } else if (guiValueKind(field.kind) === 'choice') {
      const selected = choiceValues(field, value)
      if (!selected || (field.required && !selected.length)) throw new Error('Choose a value.')
      parsed = readTerm(value)
    } else if (guiValueKind(field.kind) === 'number') {
      const numeric = numericDraft(numericControlRange(field.range), value)
      if (numeric === null) throw new Error('Invalid numeric value.')
      parsed = number(numeric)
    } else if (guiValueKind(field.kind) === 'boolean') {
      if (!['true', 'false'].includes(value) || (field.required && value !== 'true')) throw new Error('Confirm this field.')
      parsed = atom(value)
    } else throw new Error('Unsupported question field.')
    return compound('field', [readTerm(field.role), parsed])
  })
  return anchoredGoal(reference, compound('gui_submit', [reference.question,
    binary(fromB64url(form.openedRevision)), readTerm(form.submit), list(fields)]))
}

export function guiQuestionCancellation(reference) {
  return anchoredGoal(reference, compound('gui_cancel', [reference.question]))
}

export function readGuiQuestionForm(binding) {
  const term = readTerm(binding)
  requireProjection(term)
  const [source, actor, opened, state, projection] = args(term, 'question_form', 5)
  const [ns, anchor, form] = args(source, 'form_ref', 3)
  const [revision, tree, token, fields, control] = args(projection, 'form_view', 5)
  const digest = term => {
    if (term.type !== 'binary' || term.value.length !== 32) throw new Error('invalid GUI identity digest')
    return b64url(term.value)
  }
  const sourceRef = { namespace: textValue(ns), anchor: digest(anchor), form: renderTerm(form) }
  const responsible = readAgentReference(renderTerm(actor))
  if (renderTerm(args(tree, 'component', 4)[0]) !== sourceRef.form) throw new Error('question form identity changed')
  const view = readGuiView(renderTerm(tree))
  const leaves = nodes => nodes.flatMap(node => node.children ? leaves(node.children) : [node])
  const controls = leaves(view.fields)
  if (controls.some(field => field.kind !== 'button' && !guiValueKind(field.kind) && !guiDisplay(field.kind))) {
    throw new Error('unsupported question control')
  }
  const submit = renderTerm(control)
  if (!controls.some(field => field.role === submit && field.kind === 'button')) throw new Error('missing question submit control')
  const inputs = new Map(controls.filter(field => guiValueKind(field.kind)).map(field => [field.role, field]))
  if (fields.type !== 'list') throw new Error('invalid question fields')
  const values = Object.create(null)
  for (const row of fields.items) {
    const [id, value] = args(row, 'field', 2)
    const role = renderTerm(id), field = inputs.get(role)
    if (!field || Object.hasOwn(values, role)) throw new Error('invalid question field identity')
    if (guiValueKind(field.kind) === 'text') {
      if (value.type !== 'binary') throw new Error('invalid question text')
      values[role] = decoder.decode(value.value)
    } else if (guiValueKind(field.kind) === 'choice') {
      values[role] = renderTerm(value)
      if (!choiceValues(field, values[role])) throw new Error('invalid question selection')
    } else if (guiValueKind(field.kind) === 'boolean') {
      if (value.type !== 'atom' || !['true', 'false'].includes(value.value)) throw new Error('invalid question boolean')
      values[role] = value.value
    } else {
      if (value.type !== 'number' || value.literal || !Number.isSafeInteger(value.value)) throw new Error('unsupported GUI integer')
      values[role] = String(value.value)
    }
  }
  if (Object.keys(values).length !== inputs.size) throw new Error('incomplete question fields')
  if (state.type !== 'atom' || state.value !== 'awaiting') {
    const [, , acceptedFields] = args(state, 'submitted', 3)
    if (acceptedFields.type !== 'list') throw new Error('invalid accepted fields')
    // Accepted fields may refer to an older schema. Preserve their exact data;
    // never reinterpret them as the current schema's editable defaults.
    for (const field of acceptedFields.items) args(field, 'field', 2)
  }
  const openedRevision = digest(opened), currentRevision = digest(revision)
  const interaction = state.type === 'atom'
    ? (openedRevision === currentRevision ? 'editable' : 'stale') : 'submitted'
  return { source: sourceRef, responsible, openedRevision,
    revision: currentRevision, valuesToken: digest(token), view, values, submit, state, interaction }
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
