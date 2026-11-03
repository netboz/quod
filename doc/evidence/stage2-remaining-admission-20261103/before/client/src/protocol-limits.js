// Browser mirror of include/quod_client_goal_limits.hrl. Keep the protocol
// values in one module so saved agent references, request encoding, and the
// unresolved-operation journal accept exactly the same shapes.
const MAX_NAMESPACE_BYTES = 255
// The directory's remaining namespace policy is mirrored here; 255 is not the
// signed format's capacity. Request text uses the actual unsigned length fields.
export const SIGNED_GOAL_LIMITS = Object.freeze({ namespaceBytes: MAX_NAMESPACE_BYTES })

const encoder = new TextEncoder()

export function utf8ByteLength(value) {
  return encoder.encode(value).length
}
