import type { OntologyReference, GuiView } from './world.js'
import type { PrologTerm } from './prolog-term.js'
import type { SignedIdentity, AgentReference, SignedGoalOptions } from './signed-client.js'
import type { ViewCallbacks } from './gui-view.js'
export type OfferedOperation = { name: string; subject: PrologTerm; revision: string; valuesToken: string;
  view: GuiView; values: Record<string,string>; submit: string; outputs: string[]; availability: string }
export function operationSubject(reference: OntologyReference, kind: 'class' | 'entity', entity: PrologTerm): PrologTerm
export function readOperationClasses(identity: SignedIdentity, human: AgentReference, reference: OntologyReference,
  options?: SignedGoalOptions): Promise<string[]>
export function readOperations(value: string, subject: PrologTerm): OfferedOperation[]
export function operationGoal(form: OfferedOperation, draft: Record<string,string>): string
export function connectOperations(identity: SignedIdentity, human: AgentReference, reference: OntologyReference,
  subject: PrologTerm, callbacks: ViewCallbacks<OfferedOperation[]>, options?: SignedGoalOptions): { close(): void }
