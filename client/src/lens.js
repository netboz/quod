// Looking through one authored lens, over the signed reads this client already
// has. There is no view session, no envelope and no stream: a projection is the
// answer to an ordinary read goal, and a later read reconciles against it.
//
// When an encoding cannot show the data it was pointed at, `view/3` has no
// answer and `diagnosis/3` names the requirements that were not met. Both are
// asked here, so a refusal arrives as a reason rather than as an empty scene.

import { binary, compound, list, renderTerm, variable } from './prolog-term.js'
import { signedGoal } from './signed-client.js'
import { readMarks } from './marks.js'

const LENS_ONTOLOGY = 'quod:lens'
const encoder = new TextEncoder()

export function viewGoal(lens, parameters) {
  return askGoal(compound('view', [
    text(lens), list(parameters.map(text)), variable('Marks'),
  ]))
}

export function diagnosisGoal(lens, parameters) {
  return askGoal(compound('diagnosis', [
    text(lens), list(parameters.map(text)), variable('Unmet'),
  ]))
}

// Read one view. The reply is either the marks, or the reasons there are none.
export async function readLensView(identity, agent, lens, parameters, options = {}) {
  const reply = await signedGoal(
    identity, { mode: 'read', agent, goal: viewGoal(lens, parameters) }, options,
  )
  if (reply.result === 'ok' && reply.bindings?.length) {
    const [{ Marks }] = reply.bindings
    return { height: reply.height, marks: readMarks(Marks) }
  }
  if (reply.result !== 'fail' && reply.result !== 'ok') {
    throw new Error(`the lens replied ${reply.result ?? 'nothing'}`)
  }
  return { height: reply.height, unmet: await readDiagnosis(
    identity, agent, lens, parameters, options) }
}

async function readDiagnosis(identity, agent, lens, parameters, options) {
  const reply = await signedGoal(
    identity, { mode: 'read', agent, goal: diagnosisGoal(lens, parameters) }, options,
  )
  if (reply.result !== 'ok') return []
  return (reply.bindings ?? []).map(({ Unmet }) => Unmet)
}

// `<<"quod:lens">> :: (Goal).` — the ontology is named by its flat binary name,
// and the terminating dot belongs to the signed text, not to what a caller types.
function askGoal(goal) {
  return `${renderTerm(text(LENS_ONTOLOGY))} :: (${renderTerm(goal)}).`
}

function text(value) {
  return binary(encoder.encode(value))
}
