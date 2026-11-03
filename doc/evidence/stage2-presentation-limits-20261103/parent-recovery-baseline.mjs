import assert from 'node:assert/strict'
import { signedGoal } from '../../../client/src/signed-client.js'
import { memoryOperationJournal } from '../../../client/src/operation-journal.js'

// Exercise the production signing/HTTP/journal owner with a delivery failure.
// The HTTP response is injected; this is not evidence of a server commit.
const bytes = value => new Uint8Array(32).fill(value)
const identity = {
  networkId: bytes(16),
  provider: { publicKey: bytes(17), sign: async () => new Uint8Array(64).buffer },
  session: { session_id: 'fixture', expires_ms: Date.now() + 60000 },
}
const journal = memoryOperationJournal()
let sends = 0
const originalFetch = globalThis.fetch
globalThis.fetch = async () => {
  sends++
  return { ok: false, status: 413, json: async () => ({ error: 'result_too_large' }) }
}
try {
  let observed
  try {
    await signedGoal(identity, {
      mode: 'execute',
      agent: { namespace: 'quod:agent-test', anchor: bytes(16), instanceText: 'human_user(alice).' },
      goal: 'assertz(saved(ok)).',
    }, { journal })
  } catch (error) { observed = error }
  const retained = await journal.list()
  console.log(JSON.stringify({ httpStatus: observed?.status, error: observed?.message,
    outcomeUnknown: observed?.outcomeUnknown === true, sends, retainedOperations: retained.length }))
  assert.equal(sends, 1, 'never replay execution')
  assert.equal(retained.length, 1, 'result delivery failure must retain original signed operation')
} finally { globalThis.fetch = originalFetch }
