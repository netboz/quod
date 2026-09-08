import assert from 'node:assert/strict'
import test from 'node:test'
import {
  encodeGoalRequest,
  postJson,
  resolveSignedOperations,
  signedCursorCommand,
  signedGoal,
} from '../src/signed-client.js'
import { memoryOperationJournal } from '../src/operation-journal.js'
import { SIGNED_GOAL_LIMITS } from '../src/protocol-limits.js'

test('optional traceparent changes only HTTP metadata, not signed request bytes', async () => {
  const previousFetch = globalThis.fetch
  const calls = []
  const body = { session_id: 'session', request: 'signed-request', signature: 'signature' }
  const traceparent = '00-123456789abcdef0123456789abcdef0-123456789abcdef0-01'
  globalThis.fetch = async (url, init) => {
    calls.push({ url, ...init })
    return jsonResponse(200, { result: 'ok' })
  }
  try {
    assert.equal((await postJson('/api/goals/execute', body)).result, 'ok')
    assert.equal((await postJson('/api/goals/execute', body, 'POST', { traceparent })).result, 'ok')
    assert.deepEqual(calls[0].headers, { 'content-type': 'application/json' })
    assert.deepEqual(calls[1].headers, { 'content-type': 'application/json', traceparent })
    assert.equal(calls[1].body, calls[0].body)
    assert.equal(calls[1].body, JSON.stringify(body))
    assert.equal(calls[1].method, calls[0].method)
    assert.equal(calls[1].url, calls[0].url)
  } finally {
    globalThis.fetch = previousFetch
  }
})

test('traced HTTP transport errors retain uncertainty and do not retry', async () => {
  const previousFetch = globalThis.fetch
  let calls = 0
  globalThis.fetch = async (_url, init) => {
    calls += 1
    assert.equal(init.headers.traceparent, '00-123456789abcdef0123456789abcdef0-123456789abcdef0-01')
    throw new TypeError('connection lost')
  }
  try {
    await assert.rejects(postJson('/api/goals/execute', { request: 'same-request' }, 'POST', {
      traceparent: '00-123456789abcdef0123456789abcdef0-123456789abcdef0-01',
    }), error => error.outcomeUnknown === true)
    assert.equal(calls, 1)
  } finally {
    globalThis.fetch = previousFetch
  }
})

test('signed goal bytes match the Erlang browser fixture', () => {
  const bytes = encodeGoalRequest({
    networkIdentity: u256(0x10),
    signingPublicKey: hex('03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8'),
    operationId: u256(0x30),
    agentNamespace: 'quod:goal-test',
    agentAnchor: u256(0x20),
    agentInstanceText: 'human_user(alice).',
    mode: 'execute',
    notAfterMs: 1_800_000_000_000,
    goal: 'assertz(saved(ok)).',
  })
  assert.equal(
    Buffer.from(bytes).toString('hex'),
    '71756f642e6167656e742e676f616c2e763100' +
      '0000000000000000000000000000000000000000000000000000000000000010' +
      '03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8' +
      '0000000000000000000000000000000000000000000000000000000000000030' +
      '000e71756f643a676f616c2d74657374' +
      '0000000000000000000000000000000000000000000000000000000000000020' +
      '0000001268756d616e5f7573657228616c696365292e' +
      '0102000001a3185c5000000000136173736572747a287361766564286f6b29292e',
  )
})

test('request encoding and journaling share the full protocol bounds', async () => {
  const bytes = encodeGoalRequest({
    networkIdentity: u256(0x10),
    signingPublicKey: u256(0x11),
    operationId: u256(0x12),
    agentNamespace: 'n'.repeat(SIGNED_GOAL_LIMITS.namespaceBytes),
    agentAnchor: u256(0x13),
    agentInstanceText: 'i'.repeat(SIGNED_GOAL_LIMITS.agentInstanceTextBytes),
    mode: 'execute',
    notAfterMs: 1_800_000_000_000,
    goal: 'g'.repeat(SIGNED_GOAL_LIMITS.goalTextBytes),
  })
  assert.ok(bytes.length <= SIGNED_GOAL_LIMITS.requestBytes)

  const request = Buffer.from(bytes).toString('base64url')
  assert.ok(request.length <= SIGNED_GOAL_LIMITS.requestBase64urlChars)
  const journal = memoryOperationJournal()
  const row = operationJournalRow(request)
  await journal.put(row)
  assert.equal((await journal.list())[0].request, request)

  await journal.put({
    ...row,
    id: 'b'.repeat(43),
    request: 'r'.repeat(SIGNED_GOAL_LIMITS.requestBase64urlChars),
  })
  await assert.rejects(
    journal.put({
      ...row,
      id: 'c'.repeat(43),
      request: 'r'.repeat(SIGNED_GOAL_LIMITS.requestBase64urlChars + 1),
    }),
    /invalid operation journal row/,
  )

  assert.throws(
    () => encodeGoalRequest({
      networkIdentity: u256(0x10),
      signingPublicKey: u256(0x11),
      operationId: u256(0x12),
      agentNamespace: 'n'.repeat(SIGNED_GOAL_LIMITS.namespaceBytes + 1),
      agentAnchor: u256(0x13),
      agentInstanceText: 'i',
      mode: 'execute',
      notAfterMs: 1_800_000_000_000,
      goal: 'true',
    }),
    /invalid signed goal/,
  )
})

test('a lost signed-goal response is marked outcome-unknown', async () => {
  const previousFetch = globalThis.fetch
  const journal = memoryOperationJournal()
  globalThis.fetch = async () => { throw new TypeError('connection lost') }
  try {
    await assert.rejects(
      signedGoal(
        {
          networkId: u256(0x10),
          provider: {
            publicKey: u256(0x11),
            sign: async () => new Uint8Array(64).buffer,
          },
          session: {
            session_id: 'session',
            expires_ms: Date.now() + 60_000,
          },
        },
        {
          mode: 'execute',
          agent: agentReference(),
          goal: 'assertz(saved(ok)).',
        },
        { journal },
      ),
      (error) => error.outcomeUnknown === true && /do not resubmit/.test(error.message),
    )
    const [pending] = await journal.list()
    assert.equal(pending.version, 2)
    assert.equal(pending.signing_key.length, 43)
    assert.deepEqual(pending.agent, {
      namespace: 'quod:agent-test',
      anchor: b64urlForTest(u256(0x10)),
      instance_text: 'human_user(alice).',
    })
    assert.equal(pending.signature.length, 86)
  } finally {
    globalThis.fetch = previousFetch
  }
})

test('exact persisted requests are resolved, never resubmitted', async () => {
  const previousFetch = globalThis.fetch
  const journal = memoryOperationJournal()
  const identity = signedIdentity()
  globalThis.fetch = async url => {
    if (url === '/api/goals/execute') throw new TypeError('reply lost')
    assert.equal(url, '/api/goals/outcomes')
    return jsonResponse(202, {
      result: 'operation_outcome', status: 'pending', terminal: false,
    })
  }
  try {
    await assert.rejects(
      signedGoal(identity, signedWrite(), { journal }),
      error => error.outcomeUnknown === true,
    )
    assert.equal((await journal.list()).length, 1)
    const [pending] = await resolveSignedOperations(identity, { journal })
    assert.equal(pending.reply.status, 'pending')
    assert.equal((await journal.list()).length, 1)

    globalThis.fetch = async url => {
      assert.equal(url, '/api/goals/outcomes')
      return jsonResponse(200, {
        result: 'operation_outcome', status: 'committed', terminal: true,
      })
    }
    const [committed] = await resolveSignedOperations(identity, { journal })
    assert.equal(committed.reply.status, 'committed')
    assert.equal((await journal.list()).length, 0)
  } finally {
    globalThis.fetch = previousFetch
  }
})

test('a definite execute reply removes the durable browser row', async () => {
  const previousFetch = globalThis.fetch
  const journal = memoryOperationJournal()
  globalThis.fetch = async () => jsonResponse(200, { result: 'ok' })
  try {
    assert.equal(
      (await signedGoal(signedIdentity(), signedWrite(), { journal })).result,
      'ok',
    )
    assert.deepEqual(await journal.list(), [])
  } finally {
    globalThis.fetch = previousFetch
  }
})

test('cursor Accept persists the original request before an uncertain reply', async () => {
  const previousFetch = globalThis.fetch
  const journal = memoryOperationJournal()
  const identity = signedIdentity()
  let calls = 0
  globalThis.fetch = async url => {
    calls += 1
    if (calls === 1) {
      assert.equal(url, '/api/goals/cursors')
      return jsonResponse(200, {
        result: 'solution', cursor: 'cursor-lost-accept', bindings: {},
      })
    }
    assert.equal(url, '/api/goals/cursors/cursor-lost-accept/accept')
    throw new TypeError('reply lost')
  }
  try {
    const open = await signedGoal(identity, signedCursor(), { journal })
    assert.equal(open.cursor, 'cursor-lost-accept')
    assert.deepEqual(await journal.list(), [])
    await assert.rejects(
      signedCursorCommand(identity, open.cursor, 'accept'),
      error => error.outcomeUnknown === true,
    )
    const [pending] = await journal.list()
    assert.equal(pending.signing_key, b64urlForTest(identity.provider.publicKey))
    assert.equal(typeof pending.request, 'string')
    assert.equal(typeof pending.signature, 'string')

    globalThis.fetch = async url => {
      assert.equal(url, '/api/goals/outcomes')
      return jsonResponse(200, {
        result: 'operation_outcome', status: 'committed', terminal: true,
      })
    }
    const [resolved] = await resolveSignedOperations(identity, { journal })
    assert.equal(resolved.reply.status, 'committed')
    assert.deepEqual(await journal.list(), [])
  } finally {
    globalThis.fetch = previousFetch
  }
})

test('retryable cursor refusal clears the journal but keeps the same cursor request', async () => {
  const previousFetch = globalThis.fetch
  const journal = memoryOperationJournal()
  const identity = signedIdentity()
  let calls = 0
  globalThis.fetch = async url => {
    calls += 1
    if (calls === 1) {
      assert.equal(url, '/api/goals/cursors')
      return jsonResponse(200, {
        result: 'solution', cursor: 'cursor-busy', bindings: {},
      })
    }
    if (calls === 2) {
      assert.equal(url, '/api/goals/cursors/cursor-busy/accept')
      return jsonResponse(409, { error: 'cursor_busy' })
    }
    assert.equal(url, '/api/goals/cursors/cursor-busy/accept')
    return jsonResponse(200, { result: 'ok' })
  }
  try {
    const open = await signedGoal(identity, signedCursor(), { journal })
    await assert.rejects(
      signedCursorCommand(identity, open.cursor, 'accept'),
      error => error.message === 'cursor_busy',
    )
    assert.deepEqual(await journal.list(), [])
    assert.equal(
      (await signedCursorCommand(identity, open.cursor, 'accept')).result,
      'ok',
    )
    assert.deepEqual(await journal.list(), [])
  } finally {
    globalThis.fetch = previousFetch
  }
})

test('missing durable storage permits reads but sends no possible write', async () => {
  const previousFetch = globalThis.fetch
  const identity = signedIdentity()
  let calls = 0
  globalThis.fetch = async url => {
    calls += 1
    if (url === '/api/goals/read') {
      return jsonResponse(200, { result: 'ok', bindings: [] })
    }
    if (url === '/api/goals/cursors') {
      return jsonResponse(200, {
        result: 'solution', cursor: 'cursor-no-storage', bindings: {},
      })
    }
    throw new Error(`unexpected fetch ${url}`)
  }
  try {
    assert.equal(
      (await signedGoal(identity, { ...signedWrite(), mode: 'read' })).result,
      'ok',
    )
    await assert.rejects(
      signedGoal(identity, signedWrite()),
      /durable browser storage is unavailable/,
    )
    const open = await signedGoal(identity, signedCursor())
    await assert.rejects(
      signedCursorCommand(identity, open.cursor, 'accept'),
      /durable browser storage is unavailable/,
    )
    assert.equal(calls, 2)
  } finally {
    globalThis.fetch = previousFetch
  }
})

test('the browser journal has no fixed unresolved-operation population limit', async () => {
  const journal = memoryOperationJournal()
  const row = operationJournalRow('request')
  for (let index = 0; index < 96; index += 1) {
    await journal.put({ ...row, id: index.toString(36).padStart(43, '0') })
  }
  await journal.put({ ...row, id: 'z'.repeat(43) })
  assert.equal((await journal.list()).length, 97)
  await journal.put({ ...row, id: '0'.repeat(43), request: 'replacement' })
  assert.equal((await journal.list()).length, 97)
})

function u256(lastByte) {
  const value = new Uint8Array(32)
  value[31] = lastByte
  return value
}

function hex(value) {
  return Uint8Array.from(Buffer.from(value, 'hex'))
}

function signedIdentity() {
  return {
    networkId: u256(0x10),
    provider: {
      publicKey: u256(0x11),
      sign: async () => new Uint8Array(64).buffer,
    },
    session: {
      session_id: 'session',
      expires_ms: Date.now() + 60_000,
    },
  }
}

function signedWrite() {
  return {
    mode: 'execute',
    agent: agentReference(),
    goal: 'assertz(saved(ok)).',
  }
}

function agentReference() {
  return {
    namespace: 'quod:agent-test',
    anchor: u256(0x10),
    instanceText: 'human_user(alice).',
  }
}

function signedCursor() {
  return {
    ...signedWrite(),
    mode: 'cursor',
    goal: 'member(X, [a,b]).',
  }
}

function operationJournalRow(request) {
  return {
    version: 2,
    id: 'a'.repeat(43),
    signing_key: 'k'.repeat(43),
    network: 'n'.repeat(43),
    agent: {
      namespace: 'quod:agent-test',
      anchor: 'a'.repeat(43),
      instance_text: 'human_user(alice).',
    },
    request,
    signature: 's'.repeat(86),
    created_at_ms: Date.now(),
  }
}

function b64urlForTest(bytes) {
  return Buffer.from(bytes).toString('base64url')
}

function jsonResponse(status, payload) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => payload,
  }
}
