// Browser mirror of include/quod_client_goal_limits.hrl. Keep the protocol
// values in one module so saved agent references, request encoding, and the
// unresolved-operation journal accept exactly the same shapes.
const MAX_NAMESPACE_BYTES = 255
const MAX_AGENT_INSTANCE_TEXT_BYTES = 8_192
const MAX_GOAL_TEXT_BYTES = 8_192

// The server deliberately reserves 32 bytes for the request domain in its
// decode-admission bound, although the current domain is shorter. Mirror that
// admission contract rather than deriving a narrower browser-only limit.
const MAX_REQUEST_BYTES = 32 + (4 * 32) + 2 + MAX_NAMESPACE_BYTES +
  4 + MAX_AGENT_INSTANCE_TEXT_BYTES + 1 + 1 + 8 + 4 + MAX_GOAL_TEXT_BYTES

export const SIGNED_GOAL_LIMITS = Object.freeze({
  namespaceBytes: MAX_NAMESPACE_BYTES,
  agentInstanceTextBytes: MAX_AGENT_INSTANCE_TEXT_BYTES,
  goalTextBytes: MAX_GOAL_TEXT_BYTES,
  requestBytes: MAX_REQUEST_BYTES,
  requestBase64urlChars: Math.ceil(MAX_REQUEST_BYTES * 4 / 3),
})

const encoder = new TextEncoder()

export function utf8ByteLength(value) {
  return encoder.encode(value).length
}
