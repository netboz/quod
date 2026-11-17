import { atom, compound, variable } from './prolog-term.js'
import { readTerm } from './prolog-read.js'
import { anchoredGoal, singleBinding, readGuiQuestionReferences, readSpaceNavigation, formLabels } from './world.js'
import { signedGoal, pendingSignedOperations, resolveSignedOperations } from './signed-client.js'
import { initializeSpace, initializeWorldLibrary, spaceKey, committed } from './space-entry.js'
import { b64url, fromB64url } from './key-provider.js'

export function readWorldLibrary(value) {
  const term = readTerm(value)
  if (term.type !== 'list' || term.tail) throw new Error('Invalid world list.')
  const keys = new Set()
  return term.items.map(row => {
    if (row.type !== 'compound' || row.functor !== 'world' || row.args.length !== 2) throw new Error('Invalid world row.')
    const [target, name] = row.args
    if (target.type !== 'compound' || target.functor !== 'entity_ref' || target.args.length !== 3 ||
        name.type !== 'binary') throw new Error('Invalid world reference.')
    const [ns, anchor, instance] = target.args
    if (ns.type !== 'binary' || anchor.type !== 'binary') throw new Error('Invalid world identity.')
    const decoder = new TextDecoder('utf-8', { fatal: true })
    const reference = { namespace: decoder.decode(ns.value), anchor: anchor.value, instance }
    const key = spaceKey(reference)
    if (keys.has(key)) throw new Error('Duplicate world identity.')
    keys.add(key)
    return { key, label: decoder.decode(name.value), reference }
  })
}

// One controller feeds the ordinary desktop and spatial GUI controls. Targets
// are re-read before execution; a cached list is never an authority grant.
export function spaceLibraryController(identity, agent, reference, view, callbacks, options = {}) {
  formLabels(view, { world: 'catalogue_selection', status: 'text_box', create: 'button', enter: 'button',
    settings: 'button', edit: 'button', refresh: 'button', setup: 'button', resolve: 'button', return: 'button' })
  const scope = JSON.stringify([reference.namespace, b64url(reference.anchor), agent.namespace,
    b64url(typeof agent.anchor === 'string' ? fromB64url(agent.anchor) : agent.anchor), agent.instanceText])
  const listeners = new Set()
  const lifetime = new AbortController()
  let running = null
  let active = true, busy = false, rows = [], selected = '', pending = 0, state = null
  let status = 'Loading your worlds…'
  const applies = operation => operation.context?.flow === 'space_library' && operation.context.scope === scope
  const context = action => ({ flow: 'space_library', scope, action })
  const publish = () => { if (active) for (const listener of listeners) listener(model()) }
  const chosen = () => rows.find(row => row.key === selected)
  const model = () => ({
    view: { ...view, fields: view.fields.map(field => field.role === 'status' ? { ...field, readonly: true } : field) },
    scope: 'Your landscapes',
    values: { world: selected, status },
    choices: { world: rows.map(row => ({ value: row.key, label: row.label })) },
    locked: busy || pending > 0,
    enabled: { create: !busy && !pending && state === 'configured', enter: !busy && !pending && !!chosen(),
      settings: !busy && !pending && state === 'configured' && !!chosen(), edit: !busy && !pending && state === 'configured' && !!chosen(),
      refresh: !busy, setup: !busy && !pending && state === 'setup_required', resolve: !busy && pending > 0, return: true },
    edit(role, value) { if (role === 'world' && !busy && !pending && rows.some(row => row.key === value)) { selected = value; publish() } },
    invoke(role) { if (active && model().enabled[role]) return invoke(role) },
    close: callbacks.close,
  })
  async function load() {
    const reply = await signedGoal(identity, { mode: 'read', agent, goal: anchoredGoal(reference,
      compound(',', [compound('world_library', [variable('Worlds')]), compound('world_library_status', [variable('State')])])),
    }, { ...options, signal: lifetime.signal })
    const next = readWorldLibrary(singleBinding(reply, 'Worlds'))
    if (next.some(row => row.reference.namespace !== reference.namespace ||
        b64url(row.reference.anchor) !== b64url(reference.anchor))) throw new Error('A world belongs to another library.')
    const state = readTerm(singleBinding(reply, 'State'))
    if (state.type !== 'atom' || !['configured', 'setup_required'].includes(state.value)) throw new Error('Invalid world tools status.')
    const operations = (await pendingSignedOperations(identity, options)).filter(applies)
    return { rows: next, state: state.value, pending: operations.length }
  }
  function install(next) {
    rows = next.rows; state = next.state; pending = next.pending
    if (!chosen()) selected = rows[0]?.key ?? ''
  }
  function work(task) {
    if (!active) return Promise.resolve()
    if (running) return running
    busy = true; publish()
    running = Promise.resolve().then(task).catch(async error => {
      const operations = await pendingSignedOperations(identity, options)
      if (active) { pending = operations.filter(applies).length; status = error.message }
    }).finally(() => {
      running = null
      if (active) { busy = false; publish() }
    })
    return running
  }
  function refresh() {
    return work(async () => {
      state = null
      const next = await load()
      if (!active) return
      install(next)
      status = pending ? 'Check the saved operation before continuing.' : state === 'setup_required' ? 'Set up world tools to create and configure landscapes.'
        : rows.length ? 'Choose a world to enter, or create another landscape.' : 'Create your first landscape.'
    })
  }
  async function terminal(reply, operation) {
    if (!applies(operation)) return false
    if (!active) return false
    if (committed(reply) && ['create', 'settings', 'edit'].includes(operation.context.action)) {
      const questions = readGuiQuestionReferences(`[${singleBinding(reply, 'Question')}]`)
      if (questions.length !== 1) throw new Error('Invalid opened form.')
      callbacks.question(questions[0])
    }
    return true
  }
  function invoke(action) {
    if (action === 'return') { callbacks.return(); return }
    if (action === 'refresh') return refresh()
    const key = selected
    status = action === 'enter' ? 'Preparing your world…' : 'Working…'
    return work(async () => {
      if (action === 'resolve') {
        for (const operation of (await pendingSignedOperations(identity, options)).filter(applies)) {
          if (!active) return
          const [result] = await resolveSignedOperations(identity, { ...options, operationId: operation.id, onTerminal: terminal })
          if (!active) return
          if (!result || result.error) throw result?.error ?? new Error('Saved outcome unavailable.')
          if (result.reply.terminal !== true) throw new Error('Outcome still unknown. Check again before continuing.')
        }
      } else {
        const next = await load()
        if (!active) return
        install(next)
        if (pending) throw new Error('Check the saved operation before continuing.')
        const row = rows.find(item => item.key === key)
        const writeOptions = { ...options, signal: lifetime.signal, context: context(action), onTerminal: terminal }
        if (action === 'setup') {
          await initializeWorldLibrary(identity, agent, reference, writeOptions)
        } else if (action === 'enter') {
          if (!row || !await readSpaceNavigation(identity, agent, row.reference, options)) throw new Error('This world is no longer available.')
          if (!active) return
          const result = await initializeSpace(identity, agent, row.reference, writeOptions)
          if (!active) return
          if (committed(result)) callbacks.enter(row.reference, row.label)
        } else {
          if (state !== 'configured') throw new Error('Set up world tools first.')
          if (action !== 'create' && !row) throw new Error('This world is no longer available.')
          const target = action === 'create' ? atom('create') : compound(action, [row.reference.instance])
          const result = await signedGoal(identity, { mode: 'execute', agent, goal: anchoredGoal(reference,
            compound('world_library_open', [target, variable('Question')])),
          }, writeOptions)
          if (!committed(result) && result.result !== 'pending') throw new Error('The form could not be opened. Check the world tools and permissions.')
        }
      }
      if (active) {
        const next = await load()
        if (!active) return
        install(next)
        status = pending ? 'The operation is saved. Check its outcome before continuing.' : 'Ready.'
      }
    })
  }
  const controller = {
    get current() { return model() },
    subscribe(listener) { listeners.add(listener); listener(model()); return () => listeners.delete(listener) },
    refresh,
    close() { active = false; lifetime.abort(); listeners.clear() },
  }
  controller.ready = refresh()
  return controller
}
