import { goalRequestBytes } from './signed-client.js'
import { b64url, fromB64url } from './key-provider.js'

export function readViewIdentity(message) {
  const integer = value => typeof value === 'string' && /^(0|[1-9][0-9]*)$/.test(value)
  if (typeof message.view !== 'string' || !integer(message.height) || !integer(message.expires_ms) ||
      !Number.isSafeInteger(Number(message.expires_ms))) throw new Error('Invalid view projection.')
  if (Number(message.expires_ms) <= Date.now()) throw new Error('View authorization expired.')
  return { view: message.view, expires: Number(message.expires_ms) }
}

// One signed-read lifecycle for ontology views. Adapters decode their data and,
// where applicable, acknowledge frames. Renewal keeps the previous authorization
// until its absolute deadline; disconnect never schedules a reconnect or write.
export function connectSignedView(identity, agent, reference, kind, goal, adapter, callbacks, options = {}) {
  const Socket = options.WebSocket ?? WebSocket
  const url = options.url ?? new URL('/api/views', globalThis.location.href)
  if (url instanceof URL) url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:'
  const socket = new Socket(String(url))
  const anchor = typeof reference.anchor === 'string' ? fromB64url(reference.anchor) : reference.anchor
  let active = true, opening = 0, expected = null, current = null
  let expiryTimer = null, renewalTimer = null
  const clearExpiry = () => {
    clearTimeout(expiryTimer); clearTimeout(renewalTimer)
    expiryTimer = null; renewalTimer = null
  }
  const discard = () => {
    clearExpiry(); opening++; expected = null; current = null
    callbacks.discard?.()
  }
  const send = message => socket.send(JSON.stringify(message))
  const failed = error => { discard(); callbacks.unavailable(error.message ?? String(error)) }
  const credit = () => {
    const message = adapter.credit?.(current)
    if (message) send(message)
  }
  async function open() {
    const version = ++opening
    if (current && Date.now() >= current.expires) { failed(new Error('View authorization expired.')); return }
    try {
      const request = goalRequestBytes(identity, { mode: 'read', agent, goal })
      const signature = new Uint8Array(await identity.provider.sign(request))
      const view = b64url(new Uint8Array(await crypto.subtle.digest('SHA-256', request)))
      if (!active || version !== opening) return
      expected = view
      send({ type: 'open', view_kind: kind, session_id: identity.session.session_id,
        request: b64url(request), signature: b64url(signature),
        view_namespace: reference.namespace, view_anchor: b64url(anchor) })
    } catch (error) { if (active && version === opening) failed(error) }
  }
  socket.onopen = open
  socket.onmessage = event => {
    if (!active) return
    try {
      const message = JSON.parse(event.data)
      if (message.type === 'refresh') {
        discard()
        if (callbacks.refreshing?.(message.reason) !== false) void open()
      } else if (message.type === 'unavailable') {
        failed(new Error(message.reason))
      } else if (message.type === 'projection' && message.view === expected) {
        const next = adapter.decode(message)
        if (current && next.expires <= current.expires) throw new Error('View authorization did not advance.')
        current = next
        expected = null
        clearExpiry()
        const remaining = current.expires - Date.now()
        expiryTimer = setTimeout(() => failed(new Error('View authorization expired.')), Math.max(0, remaining))
        // Sign-in expiry is a hard stop, not a reason for shorter renewals.
        if (current.expires < identity.session.expires_ms) {
          renewalTimer = setTimeout(() => { renewalTimer = null; void open() }, Math.max(0, remaining / 2))
        }
        callbacks.projection(current)
        credit()
      } else if (adapter.frameType && message.type === adapter.frameType && current && message.view === current.view) {
        const next = adapter.advance(current, message)
        if (next !== current) { current = next; callbacks.frame(current) }
        credit()
      }
    } catch (error) { failed(error); socket.close() }
  }
  socket.onclose = () => { if (active) failed(new Error('View disconnected. Refresh to reconnect.')) }
  socket.onerror = () => { if (active) failed(new Error('View connection unavailable.')) }
  return { get current() { return current }, get active() { return active }, fail: failed,
    close() { active = false; discard(); socket.close() } }
}
