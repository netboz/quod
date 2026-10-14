import type { SignedIdentity, AgentReference, SignedGoalOptions } from './signed-client.js'
export type ProofView = { title: string; goal: string; results: string; run: string; next: string; accept: string; stop: string; resolve: string }
export type CodeView = { title: string; predicate: string; source: string; editable: boolean;
  new_predicate?: string; results?: string; run?: string; accept?: string; stop?: string;
  create?: string; resolve?: string }
export type GuiComponent = {
  kind: string; role: string; label: string
  help?: string; enabled?: boolean; readonly?: boolean
  columns?: number; visibleRows?: number; percent?: number
  range?: { min: number; max: number; step: number }; unit?: string
  required?: boolean; multiple?: boolean; maxBytes?: number; options?: { value: string; label: string }[]
  layout?: 'column' | 'row' | 'grid'; children?: GuiComponent[]
}
export type GuiView = { title: string; enabled?: boolean; layout?: 'column' | 'row' | 'grid'; fields: GuiComponent[] }
export type OntologyReference = { namespace: string; anchor: Uint8Array }
export type EidolonChoice = { purpose: string; style: string; recipe: OntologyReference & { name: string } }
export type EidolonWorkspace = { target: OntologyReference; tools: OntologyReference; view: GuiView }
export type GuiQuestionForm = {
  source: { namespace: string; anchor: string; form: string }
  responsible: { namespace: string; anchor: string; instanceText: string }
  openedRevision: string; revision: string; valuesToken: string
  view: GuiView; values: Record<string, string>; submit: string; state: PrologTerm
  interaction: 'editable' | 'stale' | 'submitted'
}
export type GuiQuestionReference = OntologyReference & { question: PrologTerm }
export type GuiQuestionStatus = 'awaiting' | 'committed' | 'rejected' | 'aborted' | 'expired'
export function readGuiQuestionReferences(binding: string): GuiQuestionReference[]
export function readGuiQuestionStatus(identity: SignedIdentity, agent: AgentReference,
  reference: GuiQuestionReference, options?: SignedGoalOptions): Promise<GuiQuestionStatus>
export function guiQuestionSubmission(reference: GuiQuestionReference, form: GuiQuestionForm,
  draft: Record<string, string>): string
export function guiQuestionCancellation(reference: GuiQuestionReference): string
export function readGuiQuestionForm(binding: string): GuiQuestionForm
export function anchoredGoal(reference: { namespace: string; anchor: Uint8Array }, goal: unknown): string
export function readGuiView(binding: string): GuiView
export function formLabels(view: GuiView, expected: Record<string, string>): Record<string, string>
export function proofForm(view: GuiView): ProofView
export function codeForm(view: GuiView): CodeView
export class GoalFailure extends Error {
  constructor(reasons?: string[])
  accessDenied: boolean
  reasons: string[]
}
export function singleBinding(reply: Record<string, unknown>, name: string): string
export function readAgentReference(binding: string): { namespace: string; anchor: string; instanceText: string }
export function readReference(binding: string): { namespace: string; anchor: Uint8Array }
import type { PrologTerm } from './prolog-term.js'
export type Subject = { kind?: 'ontology'; ontology: string; anchor: Uint8Array | null; entity: PrologTerm }
export type WorldMark = { id: string; depicts: Subject | null }
export type MenuEntry = { id: string; label: string; view: string }
export type SpaceReference = OntologyReference & { instance: PrologTerm }
export type ViewDependency = { ns: string; genesis_anchor: string; height: string }
export function readPersonalLobby(identity: SignedIdentity, agent: AgentReference): Promise<{
  reference: SpaceReference; dependencies: ViewDependency[]; modes: string[]
} | null>
export function readDeviceMenu(identity: SignedIdentity, agent: AgentReference, subject: Subject): Promise<MenuEntry[]>
export function readEntityEidolons(identity: SignedIdentity, agent: AgentReference, subject: Subject): Promise<EidolonChoice[]>
export function readEidolonWorkspace(identity: SignedIdentity, agent: AgentReference, subject: Subject, choice: EidolonChoice): Promise<EidolonWorkspace>
