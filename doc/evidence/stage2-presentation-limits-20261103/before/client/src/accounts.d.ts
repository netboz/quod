import type { SignedIdentity, SignedGoalOptions, AgentReference } from './signed-client.js'
export type AccountOptions = SignedGoalOptions & {
  onAccount?: (agent: AgentReference & { network: string }) => void
}
export function accountReference(identity: SignedIdentity): (AgentReference & { network: string }) | null
export function readPersonalAgent(identity: SignedIdentity, human: AgentReference,
  options?: AccountOptions): Promise<{ agent: AgentReference; key: Uint8Array }>
export function readPersonalInstructions(identity: SignedIdentity, human: AgentReference,
  options?: AccountOptions): Promise<Array<{ id: string; request: Uint8Array; signature: Uint8Array }>>
export function createAccount(identity: SignedIdentity, options?: AccountOptions): Promise<Record<string, unknown>>
export function finishAccountSetup(identity: SignedIdentity, options?: AccountOptions): Promise<Record<string, unknown>>
export function resumeAccounts(identity: SignedIdentity, options?: AccountOptions): Promise<{
  results: Array<{ id: string; operation: Record<string, unknown>; reply?: Record<string, unknown>; error?: Error }>
  unresolved: number
}>
