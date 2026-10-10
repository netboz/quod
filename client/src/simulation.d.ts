import type { SignedIdentity, AgentReference } from './signed-client.js'
import type { WorldMark, SpaceReference, ViewDependency } from './world.js'
import type { PhysicsControl } from './locomotion.js'
import type { PrologTerm } from './prolog-term.js'
export type SimulationView = {
  selection: 'active'

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
export type WorldView = SimulationView | {
  selection: 'nonphysical' | 'disabled' | 'denied' | 'recovering' | 'unavailable'
  marks: WorldMark[]
  poses: Map<string, { position: number[]; rotation: number[] }>
  view: string
  expires: number
  control: null
}
export function connectWorldView(identity: SignedIdentity, agent: AgentReference, callbacks: {
  projection(view: WorldView): void
  frame(view: SimulationView): void
  unavailable(reason: string): void
  refused?(reason: string, reasons: string[]): void
  refreshing(reason: string): void | boolean
}, options: { world: SpaceReference; dependencies: ViewDependency[]; mode: string }): {
  command(input: PrologTerm): Promise<boolean>
  close(): void
}
