import { connectSignedView, readViewIdentity } from './signed-view.js'
import { anchoredGoal, readGuiQuestionForm, readGuiQuestionReferences } from './world.js'
import { compound, variable } from './prolog-term.js'
import { fromB64url } from './key-provider.js'

function connect(identity, agent, reference, kind, goal, decode, callbacks, options) {
  return connectSignedView(identity, agent, reference, kind, anchoredGoal(reference, goal), {
    decode(message) {
      if (message.kind !== kind) throw new Error('Unexpected GUI view kind.')
      return { ...readViewIdentity(message), value: decode(message.value) }
    },
  }, { ...callbacks, projection: current => callbacks.projection(current.value) }, options)
}

export function connectGuiHud(identity, agent, callbacks, options = {}) {
  const reference = { namespace: agent.namespace,
    anchor: typeof agent.anchor === 'string' ? fromB64url(agent.anchor) : agent.anchor }
  return connect(identity, agent, reference, 'gui_hud', compound('gui_pending_questions', [variable('View')]),
    readGuiQuestionReferences, callbacks, options)
}

export function connectGuiQuestion(identity, agent, reference, callbacks, options = {}) {
  return connect(identity, agent, reference, 'gui_question',
    compound('gui_question_form', [reference.question, variable('View')]), readGuiQuestionForm, callbacks, options)
}
