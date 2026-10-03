import type { Subject } from './world.js'
import type { MenuEntry } from './world.js'
import type { GuiView } from './world.js'
export type WorkspacePanelModel = {
  view: GuiView
  scope: string
  values: Record<string, string>
  choices?: Record<string, { value: string; label: string }[]>
  locked: boolean
  enabled: Record<string, boolean>
  edit(role: string, value: string): void
  invoke(role: string): void
  close(): void
}
export type WorldScene = {
  paint(marks: unknown[]): void
  setActionMenu(entries: MenuEntry[], activate: (entry: MenuEntry) => void): void
  setWorkspace(model: WorkspacePanelModel | null): void
  captureNavigation(): void
  releaseNavigation(): void
  immersive(): Promise<void>
  dispose(): void
}
export function createWorld(canvas: HTMLCanvasElement, onPick: (subject: Subject) => void, onImmersiveChanged?: (active: boolean) => void, onResourceError?: (error: Error) => void, onNavigationChanged?: (active: boolean) => void): WorldScene
