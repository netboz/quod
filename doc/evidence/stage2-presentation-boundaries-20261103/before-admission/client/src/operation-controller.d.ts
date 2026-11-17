import type { SignedIdentity, AgentReference, SignedGoalOptions } from './signed-client.js'
import type { OntologyReference } from './world.js'
import type { PrologTerm } from './prolog-term.js'
import type { WorkspacePanelModel } from './world-scene.js'
export type OperationController = { readonly current: WorkspacePanelModel; ready: Promise<void>;
  open(targets: OntologyReference[], subject?: PrologTerm): boolean;
  subscribe(listener: (model: WorkspacePanelModel) => void): () => void; close(): void }
export function operationController(identity: SignedIdentity, human: AgentReference, targets: OntologyReference[],
  callbacks: { close(): void; subject?(reference: PrologTerm): void }, options?: SignedGoalOptions & { subject?: PrologTerm }): OperationController
