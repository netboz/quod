import type { SignedIdentity, AgentReference, SignedGoalOptions } from './signed-client.js'
import type { SpaceReference, OntologyReference, GuiView, GuiQuestionReference } from './world.js'
import type { WorkspacePanelModel } from './world-scene.js'
export function readWorldLibrary(value: string): { key: string; label: string; reference: SpaceReference }[]
export type SpaceLibraryController = {
  readonly current: WorkspacePanelModel
  ready: Promise<void>
  subscribe(listener: (model: WorkspacePanelModel) => void): () => void
  refresh(): Promise<void>
  close(): void
}
export function spaceLibraryController(identity: SignedIdentity, agent: AgentReference,
  reference: OntologyReference, view: GuiView, callbacks: {
    close(): void; return(): void; enter(reference: SpaceReference, label: string): void
    question(reference: GuiQuestionReference): void
  }, options?: SignedGoalOptions): SpaceLibraryController
