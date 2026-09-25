// Browser enrollment is a sequence of ordinary signed Prolog actions. The
// existing operation journal retains the exact operation through each handoff;
// login only resolves an uncertain request, never sends it for proof again.
import { b64url, storeActiveKeyProvider } from './key-provider.js'
import { saveAgentReference } from './agent-references.js'
import { binary, compound, renderTerm, variable } from './prolog-term.js'
import { readTerm } from './prolog-read.js'
import { readAgentReference, readReference, singleBinding } from './world.js'
import { signedGoal, resolveSignedOperations, pendingSignedOperations, readSystemOntologies } from './signed-client.js'
import { signedOperationJournal } from './operation-journal.js'

export function accountReference(identity) {
  return identity.provider.accounts?.find(account => account.network === b64url(identity.networkId)) ?? null
}

export async function createAccount(identity, options = {}) {
  const journal = options.journal || signedOperationJournal()
  const pending = await accountOperations(identity, journal)
  if (pending.length) throw new Error('Account setup has an unresolved operation. Resolve it before starting another.')
  if (accountReference(identity)) throw new Error('This identity already has an account on this network.')
  const catalogue = await readSystemOntologies(identity, options)
  const services = catalogue.filter(row => row.namespace === 'quod:signup')
  if (services?.length !== 1) throw new Error('Open signup is not available on this network yet.')
  const service = services[0]
  const agent = { ...service,
    instanceText: `${renderTerm(compound('signup', [binary(identity.provider.publicKey)]))}.` }
  const token = crypto.getRandomValues(new Uint8Array(32))
  const namespace = new TextEncoder().encode(`human:${b64url(token)}`)
  const goal = `${renderTerm(compound('signup', [binary(token), binary(namespace), variable('Account')]))}.`
  const reply = await signedGoal(identity, { mode: 'execute', agent, goal }, {
    ...options, journal, context: { flow: 'account', step: 'signup' },
    onTerminal: accountResult(identity, { ...options, journal }),
  })
  if (!committed(reply) && reply.result !== 'pending') throw new Error('The signup policy refused account creation.')
  return { ...reply, unresolved: (await accountOperations(identity, journal)).length }
}

export async function resumeAccounts(identity, options = {}) {
  const journal = options.journal || signedOperationJournal()
  const results = await resolveSignedOperations(identity, {
    ...options, journal, onTerminal: accountResult(identity, { ...options, journal }),
  })
  // A resolved signup may have handed off to a new pending lobby operation.
  // Count the journal after those handoffs, not the earlier resolution snapshot.
  const remaining = await pendingSignedOperations(identity, { journal })
  return { results, unresolved: remaining.length }
}

async function accountOperations(identity, journal) {
  return (await pendingSignedOperations(identity, { journal })).filter(row => row.context?.flow === 'account')
}

function accountResult(identity, options) {
  return async (reply, operation) => {
    if (!operation.context) return
    if (operation.context.flow !== 'account') return false
    if (!committed(reply)) return
    if (operation.context.step === 'signup') {
      const reference = await rememberAccount(identity,
        readAgentReference(singleBinding(reply, 'Account')), options)
      const instance = readTerm(reference.instanceText.replace(/\.\s*$/, ''))
      const goal = `${renderTerm(compound('provision_lobby', [instance]))}, lobby_reference(Lobby).`
      // Atomic journal replacement prevents two tabs consuming the same signup
      // result from both submitting a continuation. A crash before replacement
      // retains signup; afterwards it retains only the original lobby request.
      const next = await signedGoal(identity, { mode: 'execute', agent: reference, goal }, {
        ...options, context: { flow: 'account', step: 'lobby' },
        replaceOperation: operation.id, onTerminal: accountResult(identity, options),
      })
      if (!committed(next) && next.result !== 'pending') {
        throw new Error('Your account exists, but the lobby creation was refused.')
      }
    } else if (operation.context.step === 'lobby') {
      readReference(singleBinding(reply, 'Lobby'))
      await rememberAccount(identity, { namespace: operation.agent.namespace,
        anchor: operation.agent.anchor, instanceText: operation.agent.instance_text }, options)
    } else {
      throw new Error('Unknown account operation; its recovery record has been retained.')
    }
  }
}

async function rememberAccount(identity, reference, options) {
  const account = { ...reference, network: b64url(identity.networkId) }
  identity.provider.accounts = [
    ...(identity.provider.accounts || []).filter(row => row.network !== account.network), account,
  ]
  await (options.storeIdentity || storeActiveKeyProvider)(identity.provider)
  const saved = (options.saveReference || saveAgentReference)(account)
  options.onAccount?.(saved)
  return saved
}

function committed(reply) {
  return reply.result === 'ok' || (reply.result === 'operation_outcome' &&
    reply.status === 'committed' && reply.terminal === true)
}
