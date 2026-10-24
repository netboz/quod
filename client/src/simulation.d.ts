import type { SignedIdentity, AgentReference } from './signed-client.js'
import type { WorldMark, SpaceReference, ViewDependency } from './world.js'
import type { PhysicsControl } from './locomotion.js'
import type { PrologTerm } from './prolog-term.js'
export type SimulationView = {
  selection: 'active'
  origin: bigint[]
  originSeq: bigint
  terrainReady?: boolean
  terrain?: Map<string, { body: string; revision: string; digest: string; payload: Uint8Array;
    origin_mm: string[]; chunk: string[]; spacing_mm: number; costs: number[] }> | null

  marks: WorldMark[]
  poses: Map<string, { position: number[]; rotation: number[] }>
  tick: bigint
  view: string
  fence: string
  control: PhysicsControl | null
  feedback: { sequence: string; pending: boolean; result: string; origin_mm: string[] } | null
  clearance: number | null
  expires: number
  command?(input: PrologTerm): Promise<boolean>
  interest?(position: number[]): boolean
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
  projection(view: WorldView): void | Promise<void>
  frame(view: SimulationView): void | Promise<void>
  unavailable(reason: string): void
  refused?(reason: string, reasons: string[]): void
  refreshing(reason: string): void | boolean
}, options: { world: SpaceReference; dependencies: ViewDependency[]; mode: string }): {
  command(input: PrologTerm): Promise<boolean>
  close(): void
}
