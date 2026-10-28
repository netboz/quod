// Read-only cross-owner verification of the Godot-created backup and results.
import { readFile, writeFile } from 'node:fs/promises'
import assert from 'node:assert/strict'
import { importEncryptedKeyProvider, b64url, fromB64url } from '../../../client/src/key-provider.js'
import { authenticateKey, signedGoal, resolvePersonalInstruction } from '../../../client/src/signed-client.js'
import { readList } from '../../../client/src/prolog-read.js'

const [directory, origin, output] = process.argv.slice(2)
const corpus = JSON.parse(await readFile(new URL('../../../client/test/fixtures/native-contract/contracts.json', import.meta.url)))
const original = JSON.parse(await readFile(directory + '/original.json'))
const provider = await importEncryptedKeyProvider(await readFile(directory + '/account-backup.json', 'utf8'), corpus.passphrase)
assert.equal(b64url(provider.publicKey), original.public_key)
const routes = []
async function post(route, body) {
  assert(['/api/auth/challenge', '/api/auth/complete', '/api/goals/read', '/api/agents/instructions/outcomes'].includes(route))
  routes.push(route)
  const response = await fetch(new URL(route, origin), { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), signal: AbortSignal.timeout(300000) })
  const reply = await response.json()
  assert(response.ok, reply.error)
  return reply
}
const identity = await authenticateKey(provider, { post })
const human = { namespace: original.human.Namespace, anchor: fromB64url(original.human.Anchor), instanceText: original.human.InstanceText }
const rows = readList((await signedGoal(identity, { mode: 'read', agent: human, goal: 'personal_instructions(Instructions).' }, { post })).bindings[0].Instructions)
const results = []
let uncertain = 0
for (const row of rows) {
  assert.equal(row.functor, 'instruction')
  const id = b64url(row.args[0].value)
  const reply = await resolvePersonalInstruction(identity, human, id, { post })
  if (reply.terminal === true && reply.status === 'committed') results.push({ id, result: reply.bindings[0].Results, status: reply.status })
  else { assert.equal(reply.terminal, false); uncertain++ }
}
assert.deepEqual(results.map(r => r.result).sort(), ['[result(revision,1)]', '[result(revision,2)]'])
const report = { passed: true, network: b64url(identity.networkId), human: original.human, results,
  retained_unclaimed_associations: uncertain, originating_journal_used: false, writes_submitted: 0, routes,
  note: 'Unclaimed associations from deliberate negative cases remain uncertain under the existing runtime contract; absence never becomes rejection or resubmission.' }
await writeFile(output, JSON.stringify(report, null, 2) + '\n')
console.log('PASS original Save revision1 and Reset revision2 recovered exactly with the Godot backup and no originating journal; no writes submitted')
