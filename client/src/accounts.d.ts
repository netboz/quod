import type { SignedIdentity, SignedGoalOptions, AgentReference } from './signed-client.js'
export type AccountOptions = SignedGoalOptions & { onAccount?: (agent: AgentReference) => void }
export function accountReference(identity: SignedIdentity): (AgentReference & { network: string }) | null
export function createAccount(identity: SignedIdentity, options?: AccountOptions): Promise<Record<string, unknown>>
export function finishAccountSetup(identity: SignedIdentity, options?: AccountOptions): Promise<Record<string, unknown>>
export function resumeAccounts(identity: SignedIdentity, options?: AccountOptions): Promise<{
  results: Array<{ id: string; operation: Record<string, unknown>; reply?: Record<string, unknown>; error?: Error }>
  unresolved: number
}>
