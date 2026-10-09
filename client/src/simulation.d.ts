import type { SignedIdentity, AgentReference } from './signed-client.js'
import type { WorldMark } from './world.js'
import type { PhysicsControl } from './locomotion.js'
import type { PrologTerm } from './prolog-term.js'
export type SimulationView = {
  marks: WorldMark[]
  poses: Map<string, { position: number[]; rotation: number[] }>
  tick: bigint
  view: string
  fence: string
  control: PhysicsControl | null
  feedback: { sequence: string; pending: boolean; result: string } | null
  clearance: number | null
  expires: number
  command?(input: PrologTerm): Promise<boolean>
}
export function readSimulationWorld(identity: SignedIdentity, agent: AgentReference): Promise<{
  namespace: string; anchor: Uint8Array
}>
export function connectSimulation(identity: SignedIdentity, agent: AgentReference, callbacks: {
  projection(view: SimulationView): void
  frame(view: SimulationView): void
  unavailable(reason: string): void
  refused?(reason: string, reasons: string[]): void
  refreshing(): void | boolean
}, options?: { world?: { namespace: string; anchor: Uint8Array } }): {
  command(input: PrologTerm): Promise<boolean>
  close(): void
}
