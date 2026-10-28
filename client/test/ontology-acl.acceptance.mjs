import assert from 'node:assert/strict'
import { createHash, webcrypto } from 'node:crypto'
import { readFileSync, writeFileSync, openSync, closeSync, fsyncSync, renameSync } from 'node:fs'
import { join } from 'node:path'
import { createInterface } from 'node:readline'
import { fromB64url } from '../src/key-provider.js'
import { authenticateKey, readSystemOntologies, signedGoal, signedCursorCommand } from '../src/signed-client.js'
import { memoryOperationJournal } from '../src/operation-journal.js'
import { readCodeState, readCodeSource, prepareCodeEdit } from '../src/prolog-edit.js'
import { ontologySubject, ontologyTerm, readEntityEidolons, readEidolon, readTextProjection,
  anchoredGoal, codeForm, singleBinding, GoalFailure } from '../src/world.js'
import { compound, binary, variable, atom, number, list, renderTerm } from '../src/prolog-term.js'
import { readTerm } from '../src/prolog-read.js'

globalThis.crypto ??= webcrypto
const [configPath, evidence] = process.argv.slice(2)
assert(configPath && evidence, 'Launch through the Erlang acceptance fixture.')
const config = JSON.parse(readFileSync(configPath, 'utf8'))
const origin = new URL(config.origin)
assert.equal(origin.hostname, '127.0.0.1')
assert.equal(origin.protocol, 'https:')
assert.equal(config.target.namespace, 'acl-test-owned-ontology')
const lines = createInterface({ input: process.stdin })
const input = lines[Symbol.asyncIterator]()
async function barrier(phase, fields = {}) {
  process.stdout.write(JSON.stringify({ phase, ...fields }) + '\n')
  const { value, done } = await input.next()
  assert(!done, 'Fixture controller disappeared.')
  return JSON.parse(value)
}

const journal = memoryOperationJournal()
// Persist the existing client's recovery rows before transmission. The runner
// stops on pending/unknown outcomes and never sends an operation again.
async function persist() {
  const path = join(evidence, 'operations.json'), temporary = path + '.tmp'
  const fd = openSync(temporary, 'w', 0o600)
  try { writeFileSync(fd, JSON.stringify(await journal.list(), null, 2)); fsyncSync(fd) }
  finally { closeSync(fd) }
  renameSync(temporary, path)
  const directory = openSync(evidence, 'r')
  try { fsyncSync(directory) } finally { closeSync(directory) }
}
const durable = Object.fromEntries(['put', 'delete', 'replace'].map(method => [method,
  async (...args) => { await journal[method](...args); await persist() }]))
durable.list = () => journal.list()

const nativeFetch = globalThis.fetch
let mutations = 0
const cursorRequests = new Map()
let lastRequest
globalThis.fetch = async (url, options) => {
  const address = new URL(url, origin)
  assert.equal(address.origin, origin.origin, 'Fixture requests must stay on loopback.')
  let body
  if (options?.body) body = JSON.parse(options.body)
  if (address.pathname === '/api/goals/execute') { mutations++; lastRequest = body.request }
  if (address.pathname.endsWith('/accept')) {
    mutations++
    lastRequest = cursorRequests.get(address.pathname.split('/')[4])
  }
  const response = await nativeFetch(address, options)
  if (address.pathname === '/api/goals/cursors') {
    const reply = await response.clone().json()
    if (reply.result === 'solution') cursorRequests.set(reply.cursor, body.request)
  }
  return response
}

const target = { ...config.target, anchor: fromB64url(config.target.anchor) }
const subject = ontologySubject(target)
const indicator = name => compound('/', [atom(name), number(name === 'can_invoke' ? 4 : name === 'acl_test_access' ? 2 : 1)])
const reports = []
const hash = text => createHash('sha256').update(text).digest('hex')
let owner, guest, tools, workspace

async function actor(row) {
  const key = await crypto.subtle.importKey('jwk', {
    kty: 'OKP', crv: 'Ed25519', x: row.public_key, d: row.seed, ext: true,
  }, 'Ed25519', false, ['sign'])
  const provider = { publicKey: fromB64url(row.public_key), sign: bytes => crypto.subtle.sign('Ed25519', key, bytes) }
  const identity = await authenticateKey(provider)
  assert.equal(Buffer.from(identity.networkId).toString('base64url'), config.network)
  return { identity, agent: { ...row.agent, anchor: fromB64url(row.agent.anchor) } }
}

const source = (who, name) => readCodeSource(who.identity, who.agent, workspace, indicator(name))
const full = who => readCodeState(who.identity, who.agent, workspace)
const edit = (who, name, before, after) => prepareCodeEdit(who.identity, who.agent, workspace, indicator(name), before, after)
const execute = (who, goal) => signedGoal(who.identity, { mode: 'execute', agent: who.agent, goal }, { journal: durable })
async function commit(who, goal) {
  const reply = await execute(who, goal)
  assert.equal(reply.result, 'ok', 'A pending/unknown write must be resolved, never resubmitted.')
  await barrier('settle', { request: lastRequest })
  return reply
}
const height = async () => (await barrier('height')).height
async function unchangedAfter(who, goal) {
  const beforeHeight = await height(), before = await full(owner)
  const reply = await execute(who, goal)
  assert.equal(reply.result, 'fail')
  assert.equal(await height(), beforeHeight)
  assert.equal(await full(owner), before)
  return reply
}
async function query(who, reference, goal) {
  return signedGoal(who.identity, { mode: 'read', agent: who.agent, goal: anchoredGoal(reference, goal) })
}
async function presentation(who) {
  const choices = await readEntityEidolons(who.identity, who.agent, subject)
  const choice = choices.filter(c => c.style === 'source')
  assert.equal(choice.length, 1)
  const view = await readEidolon(who.identity, who.agent, subject, choice[0])
  assert.equal(view.kind, 'workspace')
  assert.equal(view.workspace.target.namespace, target.namespace)
  assert.deepEqual(view.workspace.target.anchor, target.anchor)
  return codeForm(view.workspace.view).editable
}
async function policy(who) {
  const choices = await readEntityEidolons(who.identity, who.agent, subject)
  const choice = choices.filter(c => c.style === 'policy')
  assert.equal(choice.length, 1)
  const view = await readEidolon(who.identity, who.agent, subject, choice[0])
  assert.equal(view.kind, 'lens')
  assert.equal(view.target.namespace, target.namespace)
  assert.deepEqual(view.target.anchor, target.anchor)
  return readTextProjection(who.identity, who.agent, view.lens,
    compound('view', [binary(new TextEncoder().encode(view.view)), view.parameters, variable('View')]), 'View')
}
async function grant(mode) {
  const guestRef = compound('agent_instance_ref', [binary(new TextEncoder().encode(guest.agent.namespace)),
    binary(guest.agent.anchor), readTerm(guest.agent.instanceText.replace(/\.\s*$/, ''))])
  const replacement = mode ? renderTerm(compound('acl_test_access', [guestRef, atom(mode)])) + '.' : ''
  await commit(owner, await edit(owner, 'acl_test_access', await source(owner, 'acl_test_access'), replacement))
}
async function finishHeldSnapshot(who, reply) {
  const id = reply.cursor, decoder = new TextDecoder('utf-8', { fatal: true }), chunks = []
  try {
    while (true) {
      assert.equal(reply.result, 'solution')
      const chunk = readTerm(singleBinding({ ...reply, result: 'ok' }, 'Source'))
      assert.equal(chunk.functor, 'source_chunk')
      chunks.push(decoder.decode(chunk.args[1].value, { stream: true }))
      if (chunk.args[0].value === 'done') return chunks.join('') + decoder.decode()
      assert.equal(chunk.args[0].value, 'more')
      reply = await signedCursorCommand(who.identity, id, 'next')
    }
  } finally { await signedCursorCommand(who.identity, id, 'stop') }
}

try {
  owner = await actor(config.owner); guest = await actor(config.guest)
  assert.notDeepEqual(owner.identity.provider.publicKey, guest.identity.provider.publicKey)
  const catalogue = await readSystemOntologies(owner.identity)
  assert(!catalogue.some(row => row.namespace === target.namespace))
  const row = catalogue.find(row => row.namespace === 'quod:gui')
  assert(row)
  tools = { namespace: row.namespace, anchor: fromB64url(row.anchor) }
  workspace = { target, tools }
  assert.equal(await presentation(owner), true)
  assert.deepEqual(await readEntityEidolons(owner.identity, owner.agent, subject),
    await readEntityEidolons(owner.identity, owner.agent, ontologySubject(tools)))
  await assert.rejects(full(guest), error => error instanceof GoalFailure)
  const wrong = { ...workspace, target: { ...target, anchor: new Uint8Array(32) } }
  await assert.rejects(readCodeState(owner.identity, owner.agent, wrong), error => error instanceof GoalFailure)
  reports.push('ordinary selection, exact anchors, private discovery, independent keys')

  await grant('read')
  assert.equal(await presentation(guest), false)
  assert.equal(await full(owner), await full(guest))
  assert.equal(await policy(owner), await policy(guest))
  assert.equal((await query(guest, target, compound('acl_test_value', [variable('Value')]))).result, 'fail')
  const initial = await source(guest, 'acl_test_value')
  await unchangedAfter(guest, await edit(guest, 'acl_test_value', initial, 'acl_test_value(read_only_violation).'))
  await unchangedAfter(guest, await prepareCodeEdit(guest.identity, guest.agent, workspace, null,
    await full(guest), (await full(guest)).replace('acl_test_value(initial)', 'acl_test_value(forbidden)')))
  reports.push('source and policy reads independent of invocation and content edits')

  await grant('edit')
  assert.equal(await presentation(guest), true)
  const policyBefore = await source(guest, 'can_invoke')
  await unchangedAfter(guest, await edit(guest, 'can_invoke', policyBefore,
    policyBefore + 'can_invoke(_, _, _, _).'))
  // A content-authorized transaction cannot hide a policy write in its tail.
  const forged = compound('transaction', [compound(',', [
    compound(';', [compound('->', [compound('$quod_predicate_source',
      [indicator('acl_test_value'), variable('Expected')]), atom('true')]),
    compound('fail_with_reason', [compound('edit_conflict', [indicator('acl_test_value')])])]),
    compound('assertz', [compound('can_invoke', [variable('G'), variable('P'), variable('C'), variable('N')])]),
  ])])
  await unchangedAfter(guest, anchoredGoal(target, forged))
  const beforeEdit = await height()
  await commit(guest, await edit(guest, 'acl_test_value', initial, 'acl_test_value(guest_committed).'))
  assert.equal(await height(), beforeEdit + 1)
  assert.equal(await source(owner, 'acl_test_value'), 'acl_test_value(guest_committed) :- true.\n')
  assert.equal(await source(owner, 'can_invoke'), policyBefore)
  reports.push('authorized transactional content edit; policy edits and smuggled writes denied')

  const completeBefore = await full(guest)
  const completeDraft = completeBefore.replace('acl_test_value(guest_committed)', 'acl_test_value(multiple)') +
    'acl_test_derived(Customer) :- acl_test_value(Customer).\n'
  const completeGoal = await prepareCodeEdit(guest.identity, guest.agent, workspace, null, completeBefore, completeDraft)
  const completeHeight = await height()
  await commit(guest, completeGoal)
  assert.equal(await height(), completeHeight + 1, 'multiple predicates commit in one target transition')
  assert.equal(await source(owner, 'acl_test_value'), 'acl_test_value(multiple) :- true.\n')
  const derived = await readCodeSource(owner.identity, owner.agent, workspace, indicator('acl_test_derived'))
  assert.match(derived, /acl_test_derived\(V0\) :- acl_test_value\(V0\)/)
  const reflected = await query(owner, target, compound('acl_test_derived', [variable('Value')]))
  assert.equal(singleBinding(reflected, 'Value'), 'multiple')
  const completeAfter = await full(owner)
  assert(completeAfter.includes(derived.trim()))
  assert.equal(completeAfter.replace('acl_test_value(multiple) :- true.\n', '').replace(derived, ''),
    completeBefore.replace('acl_test_value(guest_committed) :- true.\n', ''),
    'every unedited shared, policy and runtime-owned clause is preserved exactly')
  assert.equal(await source(owner, 'can_invoke'), policyBefore)
  await assert.rejects(prepareCodeEdit(owner.identity, owner.agent, workspace, null, completeAfter, 'broken('),
    error => error instanceof GoalFailure && error.reasons.some(reason => reason.includes('syntax_error')))
  assert.equal(await height(), completeHeight + 1, 'parse rejection creates no write')
  const wrongEdit = await prepareCodeEdit(owner.identity, owner.agent, wrong, null, completeAfter, completeDraft)
  await unchangedAfter(owner, wrongEdit)
  const forbiddenPolicy = completeAfter + 'can_invoke(_, _, _, _).\n'
  await unchangedAfter(guest, await prepareCodeEdit(guest.identity, guest.agent, workspace, null, completeAfter, forbiddenPolicy))
  reports.push('complete text: factual and rule edits atomic; owner query and predicate lens agree; parse, wrong-anchor and policy edits refused')

  const before = await full(guest)
  const staleBaseline = await source(guest, 'acl_test_value')
  const stale = await prepareCodeEdit(guest.identity, guest.agent, workspace, null, before,
    before.replace('acl_test_value(multiple)', 'acl_test_value(stale_overwrite)'))
  const held = await signedGoal(guest.identity, { mode: 'cursor', agent: guest.agent,
    goal: anchoredGoal(tools, compound('prolog_source', [ontologyTerm(target), variable('Source')])) })
  assert.equal(held.result, 'solution')
  assert.equal(readTerm(singleBinding({ ...held, result: 'ok' }, 'Source')).args[0].value, 'more')
  await commit(owner, await edit(owner, 'acl_test_value', staleBaseline, 'acl_test_value(owner_committed).'))
  assert.equal(await finishHeldSnapshot(guest, held), before)
  const after = await full(owner)
  assert.equal(after, await full(guest))
  assert(after.includes('acl_test_value(owner_committed)'))
  const conflict = await unchangedAfter(guest, stale)
  assert(conflict.reasons.some(reason => reason.includes('edit_conflict')))
  reports.push('held UTF-8 snapshot, shared committed contents, stale baseline conflict')

  // Warm every read before measuring; receipts are already terminal at their
  // actual source owner. Latency is not used as evidence of zero storage work.
  const expectedPolicy = await policy(guest), readsBefore = mutations
  await full(guest)
  await barrier('inspect_ready')
  for (let i = 0; i < 3; i++) {
    assert.equal(await full(guest), after)
    assert.equal(await policy(guest), expectedPolicy)
  }
  assert.equal(mutations, readsBefore)
  await barrier('inspect_done')
  reports.push('unchanged source/policy inspection: zero mutations and owner trace barrier')

  const readyEdit = await edit(guest, 'acl_test_value', await source(guest, 'acl_test_value'), 'acl_test_value(revoked_write).')
  const pending = await signedGoal(guest.identity, { mode: 'cursor', agent: guest.agent, goal: readyEdit }, { journal: durable })
  assert.equal(pending.result, 'solution')
  const savedEditable = await presentation(guest)
  await grant(null)
  assert.equal(savedEditable, true)
  const revokedHeight = await height(), revokedSource = await full(owner)
  await unchangedAfter(guest, readyEdit)
  await assert.rejects(full(guest), error => error instanceof GoalFailure)
  await assert.rejects(policy(guest), error => error instanceof GoalFailure)
  await assert.rejects(presentation(guest), error => error instanceof GoalFailure)
  await assert.rejects(signedCursorCommand(guest.identity, pending.cursor, 'accept'),
    error => error.status === 409 && error.message === 'conflict_retry')
  // An admitted staged operation records its refusal in existing history;
  // that certified outcome is distinct from applying the requested contents.
  await barrier('settle', { request: lastRequest })
  const finalHeight = await height()
  assert.equal(finalHeight, revokedHeight + 1)
  assert.equal(await full(owner), revokedSource)
  assert.equal(await source(owner, 'acl_test_value'), 'acl_test_value(owner_committed) :- true.\n')
  reports.push('revoked source/policy/recipe reads, stale displayed permissions, staged accept refused')
  assert.deepEqual(await durable.list(), [])
  const result = { passed: true, checks: reports, source_sha256: hash(revokedSource),
    target: config.target, mutation_requests: mutations, final_target_height: finalHeight,
    independent_signing_keys: true, private_target_absent_from_catalogue: true,
    deployment_mutations: 0 }
  writeFileSync(join(evidence, 'result.json'), JSON.stringify(result, null, 2) + '\n', { flag: 'wx' })
  process.stdout.write(JSON.stringify({ phase: 'done' }) + '\n')
} catch (error) {
  writeFileSync(join(evidence, 'FAILURE.json'), JSON.stringify({ passed: false, checks: reports,
    error: error.stack, outcome_unknown: error.outcomeUnknown === true,
    mutation_requests: mutations }, null, 2) + '\n', { flag: 'wx' })
  throw error
} finally {
  lines.close()
  process.stdin.destroy()
}
