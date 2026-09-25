import type { Subject } from './world.js'
import type { MenuEntry } from './world.js'
export type WorldScene = {
  paint(marks: unknown[]): void
  setActionMenu(entries: MenuEntry[], activate: (entry: MenuEntry) => void): void
  immersive(): Promise<void>
  leaveImmersive(): Promise<void>
  dispose(): void
}
export function createWorld(canvas: HTMLCanvasElement, onPick: (subject: Subject) => void): WorldScene
