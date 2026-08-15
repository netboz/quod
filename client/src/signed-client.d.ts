export type KeyProvider = {
  publicKey: Uint8Array
  sign(bytes: Uint8Array): Promise<ArrayBuffer>
  keyPair: CryptoKeyPair
}

export type SignedIdentity = {
  provider: KeyProvider
  networkId: Uint8Array
  session: {
    session_id: string
    expires_ms: number
    public_key: string
    user_id: string
    namespace: string
  }
}

export type SignedClientError = Error & {
  outcomeUnknown?: boolean
  status?: number
}

export type SignedGoalMode = 'read' | 'execute' | 'cursor'
export type SignedOperationJournal = {
  put(row: Record<string, unknown>): Promise<void>
  delete(id: string): Promise<void>
  list(): Promise<Record<string, unknown>[]>
}

export function authenticateKey(provider: KeyProvider): Promise<SignedIdentity>
export function signedGoal(
  identity: SignedIdentity,
  request: { mode: SignedGoalMode; namespace: string; anchor: string | Uint8Array; goal: string },
  options?: { journal?: SignedOperationJournal },
): Promise<Record<string, unknown>>
export function signedCursorCommand(
  identity: SignedIdentity,
  cursor: string,
  command: 'next' | 'accept' | 'stop',
): Promise<Record<string, unknown>>
export function resolveSignedOperations(
  identity: SignedIdentity,
  options?: { journal?: SignedOperationJournal },
): Promise<Array<{ id: string; reply?: Record<string, unknown>; error?: Error }>>
export function goalRequestBytes(
  identity: SignedIdentity,
  request: { mode: SignedGoalMode; namespace: string; anchor: string | Uint8Array; goal: string },
): Uint8Array
export function encodeGoalRequest(request: {
  networkIdentity: Uint8Array
  userPublicKey: Uint8Array
  operationId: Uint8Array
  namespace: string
  anchor: Uint8Array
  mode: SignedGoalMode
  notAfterMs: number | bigint
  goal: string
}): Uint8Array
export function assertCrypto(): void
