import { readOperationClasses, operationSubject, connectOperations, operationGoal } from './gui-operation.js'
import { readPersonalAgent, readPersonalInstructions } from './accounts.js'
import { personalGoal, pendingSignedOperations, resolveSignedOperations, resolvePersonalInstruction } from './signed-client.js'
import { renderTerm } from './prolog-term.js'
import { readTerm, readList } from './prolog-read.js'
import { b64url } from './key-provider.js'
import { committed } from './space-entry.js'
import { guiValueKind } from './gui-values.js'

// One presentation owner for class and instance forms in both adapters. Drafts
// are local buffers; only the existing signed journal/outcome owners retain work.
export function operationController(identity, human, targets, callbacks, options = {}) {
  const listeners = new Set(), drafts = new Map(), history = new Map()
  let active = true, busy = false, recovered = false, stream = null, request = null
  let viewError = 'Select storage explicitly, then choose a class and operation.'
  let storage = '', classes = [], className = '', subject = null, offers = [], selected = '', pending = []
  let historyId = '', status = 'No instruction submitted.', result = '', subjects = []
  let exact = options.subject
  const targetKey = reference => JSON.stringify([reference.namespace, b64url(reference.anchor)])
  const reference = () => targets.find(target => targetKey(target) === storage)
  const form = () => offers.find(offer => offer.name === selected)
  const draftKey = () => subject && JSON.stringify([renderTerm(subject), selected])
  const draft = () => drafts.get(draftKey())
  const uncertain = () => pending.length > 0 || [...history.values()].some(row => !row.terminal)
  const locked = () => busy || !recovered || uncertain()
  // Discovery is a human read; execution is A's signed instruction. Advisory
  // availability for the reader cannot replace the executing actor's guard.
  const editable = () => !locked() && viewError === null && form() && !draft()?.settled && draft()?.revision === form().revision
  const local = name => `@operation/${name}`
  const selection = (name, label, rows) => ({ role: local(name), kind: 'selection', label,
    options: [{ value: '', label: `Choose ${label.toLowerCase()}` }, ...rows] })
  function model() {
    const current = form(), buffer = draft(), canEdit = !!editable()
    const fields = [{ ...selection('storage', 'Storage ontology', targets.map(target => ({ value: targetKey(target), label: target.namespace }))), enabled: !exact },
      ...(exact ? [] : [selection('class', 'Class', classes.map(value => ({ value, label: value })))]),
      selection('offer', 'Operation', offers.map(offer => ({ value: offer.name, label: offer.view.title }))),
      ...(buffer ? [{ role: local('form'), kind: 'container', label: buffer.view.title,
        enabled: canEdit, children: buffer.view.fields }] : []),
      { role: local('form_status'), kind: 'text_box', label: 'Form status', readonly: true },
      { role: local('status'), kind: 'text_box', label: 'Status', readonly: true },
      { role: local('result'), kind: 'text_area', label: 'Committed result', readonly: true },
      ...subjects.map((_, index) => ({ role: local(`subject/${index}`), kind: 'button', label: 'Open returned subject' })),
      selection('history', 'Previous instruction', [...history].map(([id, row]) => ({ value: id, label: `${id} — ${row.status}` }))),
      ...[['resolve', 'Check original outcome'], ['refresh', 'Refresh operations'],
        ['defaults', buffer && current && buffer.revision !== current.revision ? 'Adopt current fields, keeping draft' : 'Use current fields and defaults'],
        ['cancel', 'Cancel / close']].map(([name, label]) => ({ role: local(name), kind: 'button', label }))]
    return { view: { title: current?.view.title ?? 'Offered operations', fields }, scope: reference() ? `${reference().namespace}\nGenesis: ${b64url(reference().anchor)}` : 'No storage selected',
      values: { ...buffer?.values, [local('storage')]: storage, [local('class')]: className, [local('offer')]: selected,
        [local('status')]: status, [local('result')]: result, [local('history')]: historyId,
        [local('form_status')]: viewError ?? (buffer && buffer.revision !== current?.revision
          ? 'The form changed. Your draft is preserved; adopt current fields before submitting.' : 'Fields are current.') },
      locked: busy, enabled: { ...(current ? { [current.submit]: canEdit } : {}),
        ...Object.fromEntries(subjects.map((_, index) => [local(`subject/${index}`), !busy && !!callbacks.subject])),
        [local('resolve')]: !busy && (pending.length > 0 || !!historyId), [local('refresh')]: !busy,
        [local('defaults')]: !locked() && viewError === null && !!current, [local('cancel')]: true },
      edit, invoke, close: cancel }
  }
  function publish() { if (active) for (const listener of listeners) listener(model()) }
  function saveDefaults(preserve = false) {
    const current = form()
    if (!current) return
    const values = { ...current.values }, previous = draft()
    const leaves = fields => fields.flatMap(field => field.children ? leaves(field.children) : [field])
    if (preserve && previous) {
      const old = new Map(leaves(previous.view.fields).map(field => [field.role, field]))
      for (const field of leaves(current.view.fields)) if (Object.hasOwn(values, field.role) && !field.readonly &&
          guiValueKind(field.kind) === guiValueKind(old.get(field.role)?.kind) && Object.hasOwn(previous.values, field.role)) {
        values[field.role] = previous.values[field.role]
      }
    }
    drafts.set(draftKey(), { revision: current.revision, view: current.view, values,
      settled: preserve && previous?.settled })
  }
  function show(reply, id) {
    const terminal = committed(reply) || reply.result === 'fail' || reply.terminal === true
    const state = committed(reply) ? 'committed' : terminal ? reply.status ?? 'refused' : 'pending / uncertain'
    if (id) { history.set(id, { terminal, status: state }); historyId = id }
    status = terminal ? `${state}.` : 'Outcome uncertain. Check the original instruction; do not submit again.'
    result = committed(reply) ? (reply.bindings ?? []).map(bindings => bindings.Results ?? JSON.stringify(bindings)).join('\n') : ''
    subjects = []
    if (committed(reply)) for (const bindings of reply.bindings ?? []) {
      if (bindings.Results) for (const row of readList(bindings.Results)) {
        if (row.functor === 'result' && row.args?.length === 2 && row.args[1].functor === 'entity_ref') subjects.push(row.args[1])
      }
    }
    if (reply.reasons?.length) status += ` ${reply.reasons.join(' ')}`
    publish()
    return terminal
  }
  function terminal(reply, row) {
    if (!active) return false
    if (committed(reply) && row.context?.flow === 'gui_operation') {
      const buffer = drafts.get(JSON.stringify([row.context.subject, row.context.operation]))
      if (buffer) buffer.settled = true
    }
    return show(reply, row.instruction)
  }
  async function localPending() {
    const anchor = typeof human.anchor === 'string' ? human.anchor : b64url(human.anchor)
    pending = (await pendingSignedOperations(identity, options)).filter(row => row.instruction &&
      row.agent.namespace === human.namespace && row.agent.anchor === anchor && row.agent.instance_text === human.instanceText)
  }
  async function work(task, submission = false) {
    if (!active || busy) return
    busy = true; request = new AbortController(); publish()
    try { await task({ ...options, signal: request.signal }) }
    catch (error) { if (active) status = error.outcomeUnknown ? 'Outcome uncertain. Check the original instruction; do not submit again.'
      : submission ? `Submission refused: ${error.message}` : error.message }
    finally {
      try { await localPending() } catch (error) { recovered = false; status = `Saved operations unavailable: ${error.message}` }
      busy = false; request = null; publish()
    }
  }
  function observe() {
    stream?.close(); stream = null; offers = []; viewError = 'Select storage and a class.'
    if (!subject || !reference()) { publish(); return }
    viewError = 'Reading operations…'
    const expected = renderTerm(subject)
    stream = connectOperations(identity, human, reference(), subject, {
      projection(next) {
        if (!active || renderTerm(subject) !== expected) return
        offers = next; viewError = null
        if (!selected && next.length === 1) selected = next[0].name
        if (form() && !draft()) saveDefaults()
        publish()
      },
      discard() { viewError = 'Updating operations…'; publish() },
      unavailable(reason) { viewError = `Operations unavailable: ${reason}`; publish() },
    }, options)
  }
  async function selectStorage(value, io) {
    stream?.close(); stream = null; viewError = 'Select a class and operation.'; subject = null; offers = []; classes = []; className = ''; selected = ''
    storage = value
    if (reference()) classes = await readOperationClasses(identity, human, reference(), io)
    publish()
  }
  function edit(role, value) {
    if (!active || busy) return
    if (role === local('history')) { historyId = value; publish(); return }
    if (locked()) return
    if (role === local('storage') && !exact) return work(io => selectStorage(value, io))
    if (role === local('class') && classes.includes(value)) {
      className = value; selected = ''; subject = operationSubject(reference(), 'class', readTerm(value)); observe()
    } else if (role === local('offer') && offers.some(offer => offer.name === value)) {
      selected = value; if (!draft()) saveDefaults(); publish()
    } else if (editable() && Object.hasOwn(draft().values, role)) { draft().values[role] = value; publish() }
  }
  function invoke(role) {
    if (!active || !model().enabled[role]) return
    if (role.startsWith(local('subject/'))) { callbacks.subject(subjects[Number(role.slice(local('subject/').length))]); return }
    if (role === local('cancel')) return cancel()
    if (role === local('defaults')) {
      const preserve = draft()?.revision !== form().revision
      saveDefaults(preserve); status = preserve ? 'Current fields adopted. Review your preserved draft before submitting.' : ''; publish(); return
    }
    if (role === local('refresh')) return work(async io => { if (!recovered) await recover(io); observe() })
    return work(async io => {
      if (role === local('resolve')) {
        if (pending.length) {
          for (const operation of pending) {
            const [answer] = await resolveSignedOperations(identity, { ...io, operationId: operation.id,
              onTerminal: async (reply, row) => terminal(reply, row) })
            if (answer?.error) throw answer.error
            if (answer?.reply) show(answer.reply, operation.instruction)
          }
        } else if (historyId) show(await resolvePersonalInstruction(identity, human, historyId, io), historyId)
      } else {
        const current = form(), values = { ...draft().values }, target = reference()
        status = 'Checking the form and personal agent…'; result = ''; subjects = []; publish()
        const goal = operationGoal(current, values)
        const personal = await readPersonalAgent(identity, human, io)
        io.signal.throwIfAborted()
        status = 'Submitting through your personal agent…'; publish()
        const reply = await personalGoal(identity, { human, ...personal, target, goal }, { ...io,
          context: { flow: 'gui_operation', subject: renderTerm(subject), operation: current.name },
          onTerminal: async (reply, row) => terminal(reply, row) })
        if (active && reply.result === 'pending') show(reply)
      }
    }, role !== local('resolve'))
  }
  function cancel() { request?.abort(); callbacks.close() }
  const controller = { get current() { return model() },
    open(nextTargets, nextSubject) {
      if (busy || !active) return false
      targets = nextTargets
      if ((exact && renderTerm(exact)) === (nextSubject && renderTerm(nextSubject))) { publish(); return true }
      exact = nextSubject; selected = ''; className = ''; classes = []
      storage = exact ? targetKey(targets[0]) : ''; subject = exact ?? null
      observe(); return true
    },
    subscribe(listener) { listeners.add(listener); listener(model()); return () => listeners.delete(listener) },
    close() { active = false; request?.abort(); stream?.close(); listeners.clear() } }
  async function recover(io) {
    await localPending()
    const instructions = await readPersonalInstructions(identity, human, io)
    for (const row of instructions) {
      if (history.get(row.id)?.terminal) continue
      history.set(row.id, { terminal: false, status: 'unchecked' })
      show(await resolvePersonalInstruction(identity, human, row.id, io), row.id)
    }
    recovered = true
    if (exact && !subject) {
      storage = targetKey(targets[0]); subject = exact; observe()
    }
    if (uncertain()) status = 'An earlier instruction is unresolved. Check its original outcome before submitting.'
  }
  controller.ready = work(recover)
  return controller
}
