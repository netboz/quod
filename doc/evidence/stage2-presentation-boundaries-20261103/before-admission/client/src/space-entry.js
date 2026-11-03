// Account setup and explicit space entry share the same governed initializer.
// The caller owns journal context and any handoff from an earlier operation.
import { compound, variable, renderTerm } from './prolog-term.js'
import { readTerm } from './prolog-read.js'
import { anchoredGoal, singleBinding } from './world.js'
import { b64url } from './key-provider.js'
import { signedGoal, pendingSignedOperations } from './signed-client.js'

export function spaceKey(reference) {
  anchoredGoal(reference, reference.instance)
  return JSON.stringify([reference.namespace, b64url(reference.anchor), renderTerm(reference.instance)])
}

export function initializeSpace(identity, agent, reference, options = {}) {
  return initializeResource(identity, agent, reference, 'physics', [reference.instance], spaceKey(reference), options)
}

export function initializeWorldLibrary(identity, agent, reference, options = {}) {
  return initializeResource(identity, agent, reference, 'world_library', [],
    JSON.stringify([reference.namespace, b64url(reference.anchor), 'world_library']), options)
}

export async function initializeResource(identity, agent, reference, name, arguments_, setup, options = {}) {
  const pending = await pendingSignedOperations(identity, options)
  if (pending.some(row => row.context?.setup === setup && row.id !== options.replaceOperation)) {
    throw new Error('Setup has a saved operation. Check its outcome before continuing.')
  }
  const preparation = readTerm(singleBinding(await signedGoal(identity, {
    mode: 'read', agent, goal: anchoredGoal(reference,
      compound(`${name}_preparation`, [...arguments_, variable('Preparation')])),
  }, options), 'Preparation'))
  if (preparation.type === 'atom' && preparation.value === 'ready') return { result: 'ok', ready: true }
  if (preparation.type === 'atom' && preparation.value === 'disabled') return { result: 'ok', disabled: true }
  if (preparation.type !== 'compound' || preparation.functor !== 'prepared' || preparation.args.length !== 2) {
    throw new Error('The resource did not supply a valid authority preparation.')
  }
  options.signal?.throwIfAborted()
  const reply = await signedGoal(identity, { mode: 'execute', agent,
    goal: anchoredGoal(reference, compound(`${name}_initialize`, [...arguments_, ...preparation.args])),
  }, { ...options, context: { ...options.context, setup } })
  if (!committed(reply) && reply.result !== 'pending') throw new Error('The resource setup was refused.')
  return reply
}

export function committed(reply) {
  return reply.result === 'ok' || (['operation_outcome', 'group_outcome'].includes(reply.result) &&
    reply.status === 'committed' && reply.terminal === true)
}
