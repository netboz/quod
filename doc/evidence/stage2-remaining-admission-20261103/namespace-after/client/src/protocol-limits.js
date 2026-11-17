// Browser mirror of include/quod_client_goal_limits.hrl. Keep the protocol
// values in one module so saved agent references, request encoding, and the
// unresolved-operation journal accept exactly the same shapes.
// The signed request namespace field is an unsigned16-bit byte length.
export const SIGNED_GOAL_LIMITS = Object.freeze({ namespaceBytes: 2 ** 16 - 1 })

const encoder = new TextEncoder()

export function utf8ByteLength(value) {
  return encoder.encode(value).length
}
