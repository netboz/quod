// Browser enrollment is a sequence of ordinary signed Prolog actions. The
// existing operation journal retains the exact operation through each handoff;
// login only resolves an uncertain request, never sends it for proof again.
import { b64url, fromB64url, storeActiveKeyProvider } from './key-provider.js'
import { saveAgentReference } from './agent-references.js'
import { binary, compound, renderTerm, variable } from './prolog-term.js'
import { readTerm, readList } from './prolog-read.js'
import { readAgentReference, singleBinding } from './world.js'
import { signedGoal, resolveSignedOperations, pendingSignedOperations, readSystemOntologies } from './signed-client.js'
import { committed } from './space-entry.js'
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
  const services = catalogue.filter(row => row.namespace === 'quod:user')
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
  // A resolved signup may have handed off to a new pending setup operation.
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
      // The exact parent is replaced before sending; an unknown child outcome
      // remains in the existing operation journal.
      await setupAccount(identity, reference, { ...options, replaceOperation: operation.id })
    } else if (operation.context.step === 'setup') {
      const reference = await rememberAccount(identity, { namespace: operation.agent.namespace,
        anchor: operation.agent.anchor, instanceText: operation.agent.instance_text }, options)
      checkSetup(reference, readTerm(singleBinding(reply, 'Setup')))
    } else {
      throw new Error('Unknown account operation; its recovery record has been retained.')
    }
  }
}

export async function readPersonalAgent(identity, human, options = {}) {
  const reply = await signedGoal(identity, { mode: 'read', agent: human,
    goal: 'personal_agent(Agent, Key).' }, options)
  const key = readTerm(singleBinding(reply, 'Key'))
  if (key.type !== 'binary' || key.value.length !== 32) throw new Error('The personal agent key is unavailable.')
  return { agent: readAgentReference(singleBinding(reply, 'Agent')), key: key.value }
}

// Authoritative discovery also works after all browser operation records have
// been cleared. Enumeration grants no dispatch permission.
export async function readPersonalInstructions(identity, human, options = {}) {
  const reply = await signedGoal(identity, { mode: 'read', agent: human,
    goal: 'personal_instructions(Instructions).' }, options)
  return readList(singleBinding(reply, 'Instructions')).map(row => {
    if (row.type !== 'compound' || row.functor !== 'instruction' || row.args.length !== 3 ||
        row.args.some(value => value.type !== 'binary') || row.args[0].value.length !== 32) {
      throw new Error('The personal instruction association is invalid.')
    }
    return { id: b64url(row.args[0].value), request: row.args[1].value, signature: row.args[2].value }
  })
}

// Explicit user action for an account whose setup was refused before admission.
// An unresolved enrollment must be resolved first, never replaced by this action.
export async function finishAccountSetup(identity, options = {}) {
  const journal = options.journal || signedOperationJournal()
  if ((await accountOperations(identity, journal)).length) {
    throw new Error('Account setup has an unresolved operation. Resolve it before continuing.')
  }
  const reference = accountReference(identity)
  if (!reference) throw new Error('This identity has no account on this network.')
  return setupAccount(identity, reference, { ...options, journal })
}

async function setupAccount(identity, reference, options) {
  const preparation = await signedGoal(identity, { mode: 'read', agent: reference,
    goal: 'account_setup_preparation(Preparation).' }, options)
  const prepared = readTerm(singleBinding(preparation, 'Preparation'))
  if (prepared.type !== 'compound') throw new Error('Account setup preparation is unavailable.')
  if (prepared.functor === 'complete' && prepared.args.length === 1) {
    checkSetup(reference, prepared.args[0])
    return preparation
  }
  if (prepared.functor !== 'prepared' || prepared.args.length !== 3) {
    throw new Error('Account setup preparation is invalid.')
  }
  const [storage, node, key] = prepared.args
  const goal = `${renderTerm(compound('setup_account', [storage,node,key,variable('Setup')]))}.`
  const reply = await signedGoal(identity, { mode: 'execute', agent: reference, goal }, {
    ...options, context: { flow: 'account', step: 'setup' },
    onTerminal: accountResult(identity, options),
  })
  if (!committed(reply) && reply.result !== 'pending') {
    throw new Error('Your account exists, but setup was refused.')
  }
  return reply
}

function checkSetup(reference, result) {
  if (result.type !== 'compound' || result.functor !== 'account' || result.args.length !== 6) {
    throw new Error('The account setup result is invalid.')
  }
  const owner = readAgentReference(renderTerm(result.args[0]))
  const agent = readAgentReference(renderTerm(result.args[1]))
  if (owner.namespace !== reference.namespace || owner.anchor !== reference.anchor ||
      owner.instanceText !== reference.instanceText || agent.namespace !== owner.namespace ||
      agent.anchor !== owner.anchor || agent.instanceText === owner.instanceText) {
    throw new Error('The account setup returned different identities.')
  }
  const storage = result.args[3]
  if (storage.type !== 'compound' || storage.functor !== 'ontology_ref' || storage.args.length !== 2 ||
      storage.args[0].type !== 'binary' || storage.args[1].type !== 'binary' ||
      new TextDecoder().decode(storage.args[0].value) !== reference.namespace ||
      b64url(storage.args[1].value) !== reference.anchor) {
    throw new Error('The account setup returned different storage.')
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
