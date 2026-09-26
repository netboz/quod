import type { Subject } from './world.js'
import type { MenuEntry } from './world.js'
import type { ProofView } from './world.js'
export type ProofPanelModel = {
  view: ProofView
  scope: string
  goal: string
  result: string
  locked: boolean
  enabled: Record<'run' | 'next' | 'accept' | 'stop', boolean>
  edit(goal: string): void
  run(): void
  next(): void
  accept(): void
  stop(): void
  close(): void
}
export type WorldScene = {
  paint(marks: unknown[]): void
  setActionMenu(entries: MenuEntry[], activate: (entry: MenuEntry) => void): void
  setWorkspace(model: ProofPanelModel | null): void
  immersive(): Promise<void>
  dispose(): void
}
export function createWorld(canvas: HTMLCanvasElement, onPick: (subject: Subject) => void, onImmersiveChanged?: (active: boolean) => void): WorldScene
