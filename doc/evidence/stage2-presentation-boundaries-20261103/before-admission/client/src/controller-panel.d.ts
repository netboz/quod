import type { WorldScene, WorkspacePanelModel } from './world-scene.js'
export function controllerPanel(scene: () => WorldScene | null, callbacks: { close(): void; settings(): void }): {
  readonly current: WorkspacePanelModel; refresh(): void;
  subscribe(listener: (model: WorkspacePanelModel) => void): () => void
}
