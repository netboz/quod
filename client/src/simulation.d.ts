import type { SignedIdentity, AgentReference } from './signed-client.js'
import type { WorldMark } from './world.js'
export type SimulationView = {
  marks: WorldMark[]
  poses: Map<string, { position: number[]; rotation: number[] }>
  tick: bigint
  view: string
}
export function connectSimulation(identity: SignedIdentity, agent: AgentReference, callbacks: {
  projection(view: SimulationView): void
  frame(view: SimulationView): void
  unavailable(reason: string): void
  refreshing(): void
}): { close(): void }
