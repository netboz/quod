import { connectSignedView, readViewIdentity } from './signed-view.js'
import { anchoredGoal, readGuiQuestionForm, readGuiQuestionReferences } from './world.js'
import { binary, compound, variable } from './prolog-term.js'
import { readTerm } from './prolog-read.js'
import { b64url, fromB64url } from './key-provider.js'
import { pendingSignedOperations, signedGoal } from './signed-client.js'

function connect(identity, agent, reference, kind, goal, decode, callbacks, options) {
  return connectSignedView(identity, agent, reference, kind, anchoredGoal(reference, goal), {
    decode(message) {
      if (message.kind !== kind) throw new Error('Unexpected GUI view kind.')
      return { ...readViewIdentity(message), value: decode(message.value),
        receiver: kind === 'gui_hud' ? readReceiver(message.receiver) : null }
    },
  }, { ...callbacks, projection: current => callbacks.projection(current.value, current.receiver) }, options)
}

function readReceiver(receiver) {
  const key = value => {
    if (typeof value !== 'string') throw new Error('Invalid GUI receiver.')
    const bytes = fromB64url(value)
    if (bytes.length !== 32 || b64url(bytes) !== value) throw new Error('Invalid GUI receiver.')
    return bytes
  }
  return { node: key(receiver?.node), token: key(receiver?.token) }
}

export function connectGuiHud(identity, agent, callbacks, options = {}) {
  const reference = { namespace: agent.namespace,
    anchor: typeof agent.anchor === 'string' ? fromB64url(agent.anchor) : agent.anchor }
  let active = true, selected = null, selectionError = null
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
      callbacks.projection(references)
      if (selectionError) callbacks.unavailable(selectionError)
      void select(receiver)
    } }, options)
  const close = stream.close
  stream.close = () => { active = false; close() }
  return stream
}

export function connectGuiQuestion(identity, agent, reference, callbacks, options = {}) {
  return connect(identity, agent, reference, 'gui_question',
    compound('gui_question_form', [reference.question, variable('View')]), readGuiQuestionForm, callbacks, options)
}
