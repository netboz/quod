import type { SignedIdentity, AgentReference, SignedGoalOptions } from './signed-client.js'
import type { SpaceReference, OntologyReference } from './world.js'
export function spaceKey(reference: SpaceReference): string
export function initializeSpace(identity: SignedIdentity, agent: AgentReference, reference: SpaceReference,
  options?: SignedGoalOptions): Promise<Record<string, unknown>>
export function committed(reply: Record<string, unknown>): boolean
export function initializeResource(identity: SignedIdentity, agent: AgentReference,
  reference: OntologyReference, name: string, arguments_: unknown[], setup: string,
  options?: SignedGoalOptions): Promise<Record<string, unknown>>
