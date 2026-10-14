import { connectGuiQuestion } from './gui-view.js'
import { guiQuestionSubmission, guiQuestionCancellation, readGuiQuestionStatus } from './world.js'
import { pendingSignedOperations, resolveSignedOperations, signedGoal } from './signed-client.js'
import { b64url } from './key-provider.js'
import { renderTerm } from './prolog-term.js'

export function questionKey(reference) {
  return JSON.stringify([reference.namespace, b64url(reference.anchor), renderTerm(reference.question)])
}

// Local presentation state only. Writes and recovery use the existing signed
// operation journal; the ontology owns acceptance, completion and cancellation.
export function questionController(identity, agent, reference, changed, options = {}) {
  const scope = questionKey(reference)
  const anchor = typeof agent.anchor === 'string' ? agent.anchor : b64url(agent.anchor)
  let active = true, busy = false, recovered = false, available = false, settled = null
  let form = null, draftView = null, draft = {}, pending = [], stream = null, status = 'Loading question…', outcome = null
  let draftRevision = null
  const locked = () => !active || busy || !recovered || !available || settled !== null || pending.length > 0 ||
    form?.interaction !== 'editable'
  const canCancel = () => active && !busy && recovered && settled !== 'cancel' && pending.length === 0 &&
    ((available && form?.interaction !== 'submitted' && settled !== 'submit') ||
      (outcome === 'awaiting' && settled !== 'submit') || ['rejected', 'aborted', 'expired'].includes(outcome))
  function publish() {
    if (active) changed({ form, draftView, draft: { ...draft }, locked: locked(), busy,
      pending: pending.length, status, canCancel: canCancel() })
  }
  async function recover() {
    recovered = false
    const rows = await pendingSignedOperations(identity, options)
    if (!active) return
    pending = rows.filter(row => row.agent.namespace === agent.namespace && row.agent.anchor === anchor &&
      row.agent.instance_text === agent.instanceText && row.context?.flow === 'gui_question' && row.context.scope === scope)
    recovered = true
  }
  function refresh() {
    if (!active || busy) return
    stream?.close()
    available = false
    stream = connectGuiQuestion(identity, agent, reference, {
      projection(next) {
        if (!active) return
        // Keep the draft with the schema that gave its fields meaning. A new
        // schema locks it; new defaults never silently overwrite human input.
        const defaultsChanged = form && next.valuesToken !== form.valuesToken
        if (!form || next.interaction === 'submitted' ||
            (next.interaction === 'editable' && draftRevision !== next.revision)) {
          draft = { ...next.values }; draftView = next.view; draftRevision = next.revision
        }
        form = next; available = true
        status = settled === 'cancel' ? 'Question cancelled.'
          : next.interaction === 'stale' ? 'This form changed. Editing is disabled. Cancel it and request a new one.'
          : next.interaction === 'submitted' || settled ? 'Answer submitted. Waiting for completion.'
          : defaultsChanged ? 'Defaults changed. Your draft is preserved; you can choose to use the current defaults.' : ''
        publish()
      },
      discard() { available = false; publish() },
      refreshing() { status = 'Question updating…'; publish() },
      unavailable(reason) { available = false; status = reason; publish() },
    }, options)
    publish()
  }
  async function write(action) {
    if (action === 'submit' ? locked() : !canCancel()) return
    let goal
    try { goal = action === 'submit' ? guiQuestionSubmission(reference, form, draft) : guiQuestionCancellation(reference) }
    catch (error) { status = error.message; publish(); return }
    busy = true; publish()
    try {
      const reply = await signedGoal(identity, { mode: 'execute', agent, goal }, { ...options,
        context: { flow: 'gui_question', scope, action }, onTerminal: async () => active })
      if (!active) return
      if (reply.result === 'ok') {
        settled = action
        status = action === 'submit' ? 'Answer submitted. Waiting for completion.' : 'Question cancelled.'
      } else if (reply.result === 'fail') status = ['The request was refused.', ...(reply.reasons ?? [])].join(' ')
      else status = 'Outcome not yet known. Check the saved operation.'
    } catch (error) { if (active) status = error.message ?? String(error) }
    finally {
      // A storage error must leave editing locked, even if the write reply was
      // lost before this controller learned its operation identity.
      try { await recover() } catch (error) { if (active) status = `Saved operations unavailable: ${error.message}` }
      busy = false; publish()
    }
  }
  async function resolve() {
    if (!active || busy || !recovered || pending.length === 0) return
    busy = true; publish()
    try {
      for (const row of pending) {
        const [result] = await resolveSignedOperations(identity, { ...options, operationId: row.id,
          onTerminal: async () => active })
        if (!active) return
        if (!result || result.error) throw result?.error ?? new Error('Saved outcome unavailable.')
        if (result.reply.terminal !== true) { status = 'Outcome still unknown. Do not resubmit.'; break }
        if (result.reply.status === 'committed') settled = row.context.action
        status = `Saved operation: ${result.reply.status}.`
      }
      await recover()
    } catch (error) { if (active) status = error.message ?? String(error) }
    finally { busy = false; publish() }
  }
  async function check() {
    if (!active || busy || pending.length) return
    busy = true; outcome = null; publish()
    try {
      const next = await readGuiQuestionStatus(identity, agent, reference, options)
      if (active) { outcome = next; status = `Answer status: ${next}.` }
    } catch (error) { if (active) status = `Answer status unavailable: ${error.message}` }
    finally { busy = false; publish() }
  }
  const ready = recover().catch(error => { if (active) status = `Saved operations unavailable: ${error.message}` })
    .then(() => publish())
  refresh()
  return { ready, refresh, resolve, check,
    submit: () => write('submit'), cancel: () => write('cancel'),
    resetDraft() {
      if (!locked()) {
        draft = { ...form.values }; draftView = form.view; draftRevision = form.revision; status = ''; publish()
      }
    },
    edit(role, value) {
      if (!locked() && Object.hasOwn(draft, role) && typeof value === 'string') {
        draft = { ...draft, [role]: value }; publish()
      }
    },
    close() { active = false; stream?.close() },
  }
}
