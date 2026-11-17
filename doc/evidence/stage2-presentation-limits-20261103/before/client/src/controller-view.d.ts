import type { SignedIdentity, AgentReference } from './signed-client.js'
export type ControllerMapping = { revision: number; digest: string; roles: Record<string, string>; bindings: unknown[]; profiles: unknown[] }
export function readControllerView(value: string): ControllerMapping | null
export function connectControllerView(identity: SignedIdentity, human: AgentReference, callbacks: {
  projection(mapping: ControllerMapping | null): void; discard?(): void; unavailable(reason: string): void
}): { close(): void }
