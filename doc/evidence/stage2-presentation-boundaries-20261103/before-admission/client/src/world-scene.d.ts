import type { ControllerMapping } from './controller-view.js'
import type { Subject } from './world.js'
import type { MenuEntry } from './world.js'
import type { GuiView } from './world.js'
import type { WorldView } from './simulation.js'
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
  update(view: WorldView | { marks: unknown[]; selection: 'nonphysical' | 'unavailable' } | null): Promise<void>
  setActionMenu(entries: MenuEntry[], activate: (entry: MenuEntry) => void): void
  setControllerMapping(mapping: ControllerMapping | null): void
  chooseController(role: string, id: string): boolean | void
  controllerStatus(): { available: boolean; choices: Record<string, string>; sources: { id: string; hand: string; profile: string; tracked: boolean; bindings: string[]; reason: string }[] }
  setWorkspace(model: WorkspacePanelModel | null): void
  releaseNavigation(): void
  immersive(): Promise<void>
  exitImmersive(): Promise<void>
  dispose(): Promise<void>
}
export type XRState = 'preparing' | 'ready' | 'starting' | 'presenting' | 'stopping' | 'blocked' | 'unavailable' | 'disposed'
export function createWorld(canvas: HTMLCanvasElement, onPick: (subject: Subject) => void, onImmersiveChanged?: (active: boolean) => void, onResourceError?: (error: Error) => void, onNavigationChanged?: (active: boolean) => void, onControllersChanged?: () => void, onXRStateChanged?: (state: XRState) => void): WorldScene
