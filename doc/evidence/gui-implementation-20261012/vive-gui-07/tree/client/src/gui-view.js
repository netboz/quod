import { connectSignedView, readViewIdentity } from './signed-view.js'
import { anchoredGoal, readGuiQuestionForm, readGuiQuestionReferences } from './world.js'
import { binary, compound, variable, renderTerm } from './prolog-term.js'
import { readTerm } from './prolog-read.js'
import { b64url, fromB64url } from './key-provider.js'
import { pendingSignedOperations, signedGoal } from './signed-client.js'

function connect(identity, agent, reference, kind, goal, decode, callbacks, options, native = {}) {
  return connectSignedView(identity, agent, reference, kind, anchoredGoal(reference, goal), {
    decode(message) {
      if (message.kind !== kind) throw new Error('Unexpected GUI view kind.')
      return { ...readViewIdentity(message), value: decode(message.value),
        receiver: kind === 'gui_hud' ? readReceiver(message.receiver) : null }
    },
    ...native,
  }, { ...callbacks, projection: current => callbacks.projection(current.value, current.receiver) }, options)
}

function receiverKey(value) {
  if (typeof value !== 'string') throw new Error('Invalid GUI receiver.')
  const bytes = fromB64url(value)
  if (bytes.length !== 32 || b64url(bytes) !== value) throw new Error('Invalid GUI receiver.')
  return bytes
}
function readReceiver(receiver) {
  return { node: receiverKey(receiver?.node), token: receiverKey(receiver?.token) }
}

export function connectGuiHud(identity, agent, callbacks, options = {}) {
  const reference = { namespace: agent.namespace,
    anchor: typeof agent.anchor === 'string' ? fromB64url(agent.anchor) : agent.anchor }
  let active = true, selected = null, selectionError = null, receiverToken = null
  const resources = new Map()
  function dispose(token) {
    const resource = resources.get(token)
    if (!resource) return
    resources.delete(token); clearTimeout(resource.timer); resource.handle.dispose()
  }
  const native = {
    close() { receiverToken = null; for (const token of resources.keys()) dispose(token) },
    message(message, current, send) {
      if (!['gui_prepare', 'gui_activate', 'gui_expired'].includes(message.type)) return false
      receiverKey(message.token)
      if (message.type === 'gui_expired') { dispose(message.token); return true }
      const previous = resources.get(message.token)
      if (message.type === 'gui_activate') {
        let status = 'expired'
        if (previous && previous.expires > Date.now()) {
          if (previous.activated || previous.handle.activate()) {
            previous.activated = true; status = 'active'
          }
        }
        if (status === 'expired') dispose(message.token)
        send({ type: 'gui_activated', token: message.token, status })
        return true
      }
      let accepted = false
      try {
        const expires = Number(message.expires_ms)
        if (!current || current.expires <= Date.now() || message.connection !== receiverToken ||
            !/^(0|[1-9][0-9]*)$/.test(message.expires_ms) || !Number.isSafeInteger(expires) || expires <= Date.now() ||
            expires - Date.now() > 2147483647 ||
            !Number.isSafeInteger(message.capacity) || message.capacity <= 0) throw new Error('Invalid preparation.')
        if (previous) accepted = previous.expires > Date.now()
        else if (resources.size < message.capacity) {
          const references = readGuiQuestionReferences(`[${message.question}]`)
          if (references.length !== 1) throw new Error('Invalid question reference.')
          const [question] = references
          const form = readGuiQuestionForm(message.descriptor)
          const handle = callbacks.prepare?.(question, form)
          if (handle) {
            const timer = setTimeout(() => dispose(message.token), expires - Date.now())
            resources.set(message.token, { handle, timer, expires, question, activated: false })
            accepted = true
          }
        }
      } catch { /* Unsupported descriptors refuse this resource, not the HUD. */ }
      send({ type: 'gui_prepared', token: message.token, accepted })
      return true
    },
  }
  const anchor = b64url(reference.anchor)
  async function select(receiver) {
    const id = `${b64url(receiver.node)}:${b64url(receiver.token)}`
    if (selected === id) return
    selected = id
    try {
      const pending = await pendingSignedOperations(identity, options)
      if (!active) return
      if (pending.some(row => row.agent.namespace === agent.namespace && row.agent.anchor === anchor &&
          row.agent.instance_text === agent.instanceText && row.context?.flow === 'gui_receiver')) {
        throw new Error('A saved receiver selection needs outcome resolution before selecting this connection.')
      }
      const goal = anchoredGoal(reference, compound('gui_select_receiver', [readTerm(agent.instanceText.replace(/\.\s*$/, '')),
        binary(receiver.node), binary(receiver.token)]))
      const reply = await signedGoal(identity, { mode: 'execute', agent, goal }, { ...options,
        context: { flow: 'gui_receiver', scope: agent.namespace }, onTerminal: async () => active })
      if (reply.result !== 'ok') throw new Error(reply.result === 'fail'
        ? 'Receiver selection was refused.' : 'Receiver selection outcome is unknown. Check the saved operation.')
    } catch (error) {
      if (active) { selectionError = error.message ?? String(error); callbacks.unavailable(selectionError) }
    }
  }
  const stream = connect(identity, agent, reference, 'gui_hud', compound('gui_pending_questions', [variable('View')]),
    readGuiQuestionReferences, { ...callbacks, projection(references, receiver) {
      receiverToken = b64url(receiver.token)
      callbacks.projection(references)
      for (const [token, resource] of resources) {
        if (resource.activated && !references.some(question =>
          question.namespace === resource.question.namespace &&
          b64url(question.anchor) === b64url(resource.question.anchor) &&
          renderTerm(question.question) === renderTerm(resource.question.question))) dispose(token)
      }
      if (selectionError) callbacks.unavailable(selectionError)
      void select(receiver)
    }, discard() { receiverToken = null; callbacks.discard?.() } }, options, native)
  const close = stream.close
  stream.close = () => { active = false; close() }
  return stream
}

export function connectGuiQuestion(identity, agent, reference, callbacks, options = {}) {
  return connect(identity, agent, reference, 'gui_question',
    compound('gui_question_form', [reference.question, variable('View')]), readGuiQuestionForm, callbacks, options)
}
