export type KeyProvider = {
  publicKey: Uint8Array
  sign(bytes: Uint8Array): Promise<ArrayBuffer>
  keyPair: CryptoKeyPair
  accounts?: Array<{ network: string; namespace: string; anchor: string; instanceText: string }>
}

export type SignedIdentity = {
  provider: KeyProvider
  networkId: Uint8Array
  session: {
    session_id: string
    expires_ms: number
    public_key: string
  }
}

export type SignedClientError = Error & {
  outcomeUnknown?: boolean
  status?: number
}

export type SignedGoalMode = 'read' | 'execute' | 'cursor'
export type AgentReference = {
  id?: string
  namespace: string
  anchor: string | Uint8Array
  instanceText: string
}
export type SignedOperationJournal = {
  put(row: Record<string, unknown>): Promise<void>
  delete(id: string): Promise<void>
  replace(id: string, row: Record<string, unknown>): Promise<void>
  list(): Promise<Record<string, unknown>[]>
}

export function authenticateKey(provider: KeyProvider): Promise<SignedIdentity>
export function readSystemOntologies(identity: SignedIdentity): Promise<Array<{ namespace: string; anchor: string }>>
export function pendingSignedOperations(identity: SignedIdentity, options?: SignedGoalOptions): Promise<Array<Record<string, unknown>>>
export type SignedGoalOptions = {
  journal?: SignedOperationJournal
  context?: Record<string, unknown>
  replaceOperation?: string
  onTerminal?: (reply: Record<string, unknown>, operation: Record<string, unknown>) => Promise<void | boolean>
}
export function signedGoal(
  identity: SignedIdentity,
  request: { mode: SignedGoalMode; agent: AgentReference; goal: string },
  options?: SignedGoalOptions,
): Promise<Record<string, unknown>>
export function signedCursorCommand(
  identity: SignedIdentity,
  cursor: string,
  command: 'next' | 'accept' | 'stop',
): Promise<Record<string, unknown>>
export function resolveSignedOperations(
  identity: SignedIdentity,
  options?: SignedGoalOptions,
): Promise<Array<{ id: string; operation: Record<string, unknown>; reply?: Record<string, unknown>; error?: Error }>>
export function goalRequestBytes(
  identity: SignedIdentity,
  request: { mode: SignedGoalMode; agent: AgentReference; goal: string },
): Uint8Array
export function encodeGoalRequest(request: {
  networkIdentity: Uint8Array
  signingPublicKey: Uint8Array
  operationId: Uint8Array
  agentNamespace: string
  agentAnchor: Uint8Array
  agentInstanceText: string
  mode: SignedGoalMode
  notAfterMs: number | bigint
  goal: string
}): Uint8Array
export function assertCrypto(): void
