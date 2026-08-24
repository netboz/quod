import { b64url, fromB64url } from './key-provider.js'
import { signedOperationJournal } from './operation-journal.js'

const encoder = new TextEncoder()
const GOAL_DOMAIN = encoder.encode('quod.agent.goal.v1\0')
const CHALLENGE_DOMAIN = encoder.encode('quod.agent.challenge.v1\0')
const REQUEST_TTL_MS = 30_000
const PARSER_VERSION = 2
const MODE_TAG = { read: 0, execute: 1, cursor: 2 }
const cursorOperations = new Map()

// Authenticate one key through the same challenge flow used by every browser
// surface. The returned object is also the only input accepted by signedGoal.
export async function authenticateKey(provider, options = {}) {
  assertCrypto()
  const post = options.post || postJson
  const clientNonce = crypto.getRandomValues(new Uint8Array(32))
  const challenge = await post('/api/auth/challenge', {
    public_key: b64url(provider.publicKey),
    client_nonce: b64url(clientNonce),
  })
  const signature = new Uint8Array(await provider.sign(
    challengeBytes(challenge, provider.publicKey, clientNonce),
  ))
  const session = await post('/api/auth/complete', {
    challenge_id: challenge.challenge_id,
    signature: b64url(signature),
  })
  return { provider, session, networkId: fromB64url(challenge.network_id) }
}

// Sign and submit one ordinary Prolog goal. Modes select proof behaviour only;
// they do not classify predicates or create a second authorization path.
export async function signedGoal(identity, { mode, agent, goal }, options = {}) {
  const post = options.post || postJson
  const request = goalRequestBytes(identity, { mode, agent, goal })
  const signature = new Uint8Array(await identity.provider.sign(request))
  const body = signedBody(identity, request, signature)
  if (mode === 'read') return post('/api/goals/read', body)

  const operation = await operationRow(identity, request, signature)
  if (mode === 'execute') {
    const journal = options.journal || signedOperationJournal()
    return submitDurable(journal, operation, '/api/goals/execute', body, post)
  }
  const reply = await post('/api/goals/cursors', body)
  if (reply.result === 'solution' && typeof reply.cursor === 'string') {
    cursorOperations.set(
      reply.cursor,
      { journal: options.journal || null, operation },
    )
  }
  return reply
}

export async function signedCursorCommand(identity, cursor, command) {
  if (!['next', 'accept', 'stop'].includes(command)) {
    throw new Error('invalid cursor command')
  }
  const suffix = command === 'stop' ? '' : `/${command}`
  const url = `/api/goals/cursors/${encodeURIComponent(cursor)}${suffix}`
  const body = { session_id: identity.session.session_id }
  const tracked = cursorOperations.get(cursor)
  if (command === 'accept') {
    if (!tracked) throw new Error('this cursor is not bound to its signed request')
    const journal = tracked.journal || signedOperationJournal()
    try {
      await journal.put(tracked.operation)
      const reply = await postJson(url, body)
      if (reply.result !== 'pending') await journal.delete(tracked.operation.id)
      cursorOperations.delete(cursor)
      return reply
    } catch (error) {
      if (!error.outcomeUnknown) await journal.delete(tracked.operation.id)
      const retryableCursor = error.message === 'cursor_busy' ||
        error.message === 'cursor_not_ready'
      if (!retryableCursor) cursorOperations.delete(cursor)
      throw error
    }
  }
  const reply = await postJson(url, body, command === 'stop' ? 'DELETE' : 'POST')
  if (command === 'stop' || reply.result !== 'solution') cursorOperations.delete(cursor)
  return reply
}

// Reconcile every unresolved write belonging to this exact key and network.
// The same signed bytes are sent only to the outcome endpoint, never to the
// proof endpoint again.
export async function resolveSignedOperations(identity, options = {}) {
  const journal = options.journal || signedOperationJournal()
  const signingKey = b64url(identity.provider.publicKey)
  const network = b64url(identity.networkId)
  const rows = (await journal.list()).filter(
    row => row.signing_key === signingKey && row.network === network,
  )
  const results = []
  for (const row of rows) {
    try {
      const reply = await postJson('/api/goals/outcomes', {
        session_id: identity.session.session_id,
        request: row.request,
        signature: row.signature,
      })
      if (reply.terminal === true) await journal.delete(row.id)
      results.push({ id: row.id, reply })
    } catch (error) {
      results.push({ id: row.id, error })
    }
  }
  return results
}

export function goalRequestBytes(identity, { mode, agent, goal }) {
  assertCrypto()
  return encodeGoalRequest({
    networkIdentity: identity.networkId,
    signingPublicKey: identity.provider.publicKey,
    operationId: crypto.getRandomValues(new Uint8Array(32)),
    agentNamespace: agent.namespace,
    agentAnchor: typeof agent.anchor === 'string' ? fromB64url(agent.anchor) : agent.anchor,
    agentInstanceText: agent.instanceText,
    mode,
    notAfterMs: Math.min(identity.session.expires_ms, Date.now() + REQUEST_TTL_MS),
    goal,
  })
}

async function submitDurable(journal, operation, url, body, post) {
  await journal.put(operation)
  try {
    const reply = await post(url, body)
    if (reply.result !== 'pending') await journal.delete(operation.id)
    return reply
  } catch (error) {
    if (!error.outcomeUnknown) await journal.delete(operation.id)
    throw error
  }
}

async function operationRow(identity, request, signature) {
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', request))
  const decoded = decodeRequestIdentity(request)
  return {
    version: 2,
    id: b64url(digest),
    signing_key: b64url(identity.provider.publicKey),
    network: b64url(identity.networkId),
    agent: decoded,
    request: b64url(request),
    signature: b64url(signature),
    created_at_ms: Date.now(),
  }
}

function decodeRequestIdentity(request) {
  let offset = GOAL_DOMAIN.length + 32 + 32 + 32
  const namespaceLength = new DataView(
    request.buffer, request.byteOffset + offset, 2,
  ).getUint16(0, false)
  offset += 2
  const namespace = new TextDecoder().decode(request.slice(offset, offset + namespaceLength))
  offset += namespaceLength
  const anchor = b64url(request.slice(offset, offset + 32))
  offset += 32
  const instanceLength = new DataView(
    request.buffer, request.byteOffset + offset, 4,
  ).getUint32(0, false)
  offset += 4
  const instance_text = new TextDecoder().decode(request.slice(offset, offset + instanceLength))
  return { namespace, anchor, instance_text }
}

function signedBody(identity, request, signature) {
  return {
    session_id: identity.session.session_id,
    request: b64url(request),
    signature: b64url(signature),
  }
}

// Pure cross-language encoder. Keeping the random operation ID and clock in
// goalRequestBytes leaves this exact protocol function fixture-testable.
export function encodeGoalRequest({
  networkIdentity,
  signingPublicKey,
  operationId,
  agentNamespace,
  agentAnchor,
  agentInstanceText,
  mode,
  notAfterMs,
  goal,
}) {
  const modeTag = MODE_TAG[mode]
  const namespaceBytes = encoder.encode(agentNamespace)
  const instanceBytes = encoder.encode(agentInstanceText)
  const goalBytes = encoder.encode(goal)
  const deadline = BigInt(notAfterMs)
  if (modeTag === undefined || namespaceBytes.length < 1 || namespaceBytes.length > 128 ||
      instanceBytes.length < 1 || instanceBytes.length > 8_192 ||
      goalBytes.length < 1 || goalBytes.length > 8_192 || agentAnchor?.length !== 32 ||
      networkIdentity?.length !== 32 || signingPublicKey?.length !== 32 ||
      operationId?.length !== 32 || deadline < 1n || deadline > 0xffffffffffffffffn) {
    throw new Error('invalid signed goal')
  }
  const namespaceLength = uint16(namespaceBytes.length)
  const instanceLength = uint32(instanceBytes.length)
  const goalLength = uint32(goalBytes.length)
  const expiry = uint64(deadline)
  return joinBytes(
    GOAL_DOMAIN,
    networkIdentity,
    signingPublicKey,
    operationId,
    namespaceLength,
    namespaceBytes,
    agentAnchor,
    instanceLength,
    instanceBytes,
    new Uint8Array([modeTag, PARSER_VERSION]),
    expiry,
    goalLength,
    goalBytes,
  )
}

export function assertCrypto() {
  if (globalThis.crypto?.subtle) return
  throw new Error(globalThis.isSecureContext === false
    ? 'this page must be served over https for the browser to allow key handling'
    : 'this browser does not provide Web Crypto')
}

// Exported for non-browser callers that need to supply an absolute URL while
// retaining the client's one HTTP error/uncertain-outcome boundary.
export async function postJson(url, body, method = 'POST') {
  let response
  try {
    response = await fetch(url, {
      method,
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    })
  } catch (cause) {
    // The browser cannot know whether the server accepted a write before the
    // connection failed. Mark that uncertainty so a caller never turns it
    // into a fresh operation by retrying the goal.
    const error = new Error('the request outcome is unknown; do not resubmit it', { cause })
    error.outcomeUnknown = true
    throw error
  }
  const payload = await response.json().catch(() => ({}))
  if (!response.ok) {
    const error = new Error(payload.error || `request failed (${response.status})`)
    error.status = response.status
    throw error
  }
  return payload
}

function challengeBytes(challenge, publicKey, clientNonce) {
  const expiry = uint64(BigInt(challenge.expires_ms))
  return joinBytes(
    CHALLENGE_DOMAIN,
    fromB64url(challenge.network_id),
    fromB64url(challenge.node_key),
    fromB64url(challenge.challenge_id),
    publicKey,
    clientNonce,
    fromB64url(challenge.server_nonce),
    expiry,
  )
}

function uint16(value) {
  const bytes = new Uint8Array(2)
  new DataView(bytes.buffer).setUint16(0, value, false)
  return bytes
}

function uint32(value) {
  const bytes = new Uint8Array(4)
  new DataView(bytes.buffer).setUint32(0, value, false)
  return bytes
}

function uint64(value) {
  const bytes = new Uint8Array(8)
  new DataView(bytes.buffer).setBigUint64(0, value, false)
  return bytes
}

function joinBytes(...parts) {
  const length = parts.reduce((total, part) => total + part.length, 0)
  const result = new Uint8Array(length)
  let offset = 0
  for (const part of parts) {
    result.set(part, offset)
    offset += part.length
  }
  return result
}
