// The editing ontology prepares an ordinary goal. Only the existing proof
// cursor and Accept path execute it; this adapter owns no writes or retries.
import { binary, compound, variable, formatClause, formatTerm } from './prolog-term.js'
import { readTerm } from './prolog-read.js'
import { anchoredGoal, singleBinding } from './world.js'
import { signedGoal, signedCursorCommand } from './signed-client.js'

const encoder = new TextEncoder()
const decoder = new TextDecoder('utf-8', { fatal: true })
const text = value => binary(encoder.encode(value))
const targetTerm = target => compound('ontology_ref', [text(target.namespace), binary(target.anchor)])

async function query(identity, agent, tools, goal, binding) {
  const reply = await signedGoal(identity, { mode: 'read', agent, goal: anchoredGoal(tools, goal) })
  return readTerm(singleBinding(reply, binding))
}

export async function readCodePredicates(identity, agent, workspace) {
  const result = await query(identity, agent, workspace.tools,
    compound('prolog_predicates', [targetTerm(workspace.target), variable('Predicates')]), 'Predicates')
  if (result.type !== 'list' || result.tail !== null) throw new Error('invalid predicate list')
  return result.items
}

export async function readCodeSource(identity, agent, workspace, indicator) {
  const result = await query(identity, agent, workspace.tools,
    compound('prolog_source', [targetTerm(workspace.target), indicator, variable('Source')]), 'Source')
  if (result.type !== 'binary') throw new Error('invalid source text')
  return decoder.decode(result.value)
}

// One signed cursor owns the snapshot for every chunk. Publish the assembled
// text only after exhaustion; an interrupted read is never a complete view.
export async function readCodeState(identity, agent, workspace, signal) {
  let reply = await signedGoal(identity, { mode: 'cursor', agent,
    goal: anchoredGoal(workspace.tools,
      compound('prolog_source', [targetTerm(workspace.target), variable('Source')])) })
  const stream = new TextDecoder('utf-8', { fatal: true })
  const chunks = []
  try {
    while (reply.result === 'solution') {
      signal?.throwIfAborted()
      const term = readTerm(singleBinding({ ...reply, result: 'ok' }, 'Source'))
      if (term.type !== 'compound' || term.functor !== 'source_chunk' || term.args.length !== 2 ||
          term.args[0].type !== 'atom' || !['more', 'done'].includes(term.args[0].value) ||
          term.args[1].type !== 'binary') throw new Error('invalid source chunk')
      chunks.push(stream.decode(term.args[1].value, { stream: true }))
      if (term.args[0].value === 'done') return chunks.join('') + stream.decode()
      reply = await signedCursorCommand(identity, reply.cursor, 'next')
    }
    signal?.throwIfAborted()
    throw new Error('Ontology source inspection was refused or incomplete.')
  } finally {
    if (reply.result === 'solution') await signedCursorCommand(identity, reply.cursor, 'stop')
  }
}

export async function prepareCodeEdit(identity, agent, workspace, indicator, baseline, source) {
  const result = await query(identity, agent, workspace.tools,
    compound('prolog_edit_goal', [targetTerm(workspace.target), indicator,
      text(baseline), text(source), variable('Edit')]), 'Edit')
  return formatClause(result)
}

// Predicate selection is data, not executable source. The server's frozen
// parser still validates every clause and the resulting signed editing goal.
export function predicateIndicator(text) {
  const match = /^(.*)\/\s*([0-9]+)$/.exec(text.trim())
  if (!match) throw new Error('Use a predicate name and arity, for example door_open/1.')
  const name = readTerm(match[1].trim())
  const arity = Number(match[2])
  if (name.type !== 'atom' || !Number.isSafeInteger(arity)) throw new Error('Invalid predicate name or arity.')
  return compound('/', [name, { type: 'number', value: arity }])
}

// Parse only on an explicit switch to cards. The server owns the source
// grammar; typing and rearranging an opened draft remain local operations.
export async function readCodeClauses(identity, agent, workspace, source) {
  const result = await query(identity, agent, workspace.tools,
    compound('prolog_clauses', [text(source), variable('Clauses')]), 'Clauses')
  if (result.type !== 'list' || result.tail !== null) throw new Error('invalid clause list')
  return result.items.map(clause => {
    const rule = clause.type === 'compound' && clause.functor === ':-' && clause.args.length === 2
    return { head: formatTerm(rule ? clause.args[0] : clause), body: rule ? formatTerm(clause.args[1]) : '' }
  })
}

export function clausesSource(clauses) {
  return clauses.map(({ head, body }) => `${head}${body.trim() ? ` :- ${body}` : ''}.`).join('\n') + (clauses.length ? '\n' : '')
}
