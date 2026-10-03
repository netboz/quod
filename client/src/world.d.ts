import type { SignedIdentity, AgentReference } from './signed-client.js'
export type ProofView = { title: string; goal: string; results: string; run: string; next: string; accept: string; stop: string; resolve: string }
export type CodeView = { title: string; predicate: string; new_predicate: string; source: string; results: string; run: string; accept: string; stop: string; create: string; resolve: string }
export type GuiView = { title: string; fields: { kind: string; role: string; label: string }[] }
export type OntologyReference = { namespace: string; anchor: Uint8Array }
export type EidolonChoice = { purpose: string; style: string; recipe: OntologyReference & { name: string } }
export type EidolonWorkspace = { target: OntologyReference; tools: OntologyReference; view: GuiView }
export function anchoredGoal(reference: { namespace: string; anchor: Uint8Array }, goal: unknown): string
export function readGuiView(binding: string): GuiView
export function formLabels(view: GuiView, expected: Record<string, string>): Record<string, string>
export function proofForm(view: GuiView): ProofView
export function codeForm(view: GuiView): CodeView
export function singleBinding(reply: Record<string, unknown>, name: string): string
export function readAgentReference(binding: string): { namespace: string; anchor: string; instanceText: string }
export function readReference(binding: string): { namespace: string; anchor: Uint8Array }
import type { PrologTerm } from './prolog-term.js'
export type Subject = { kind?: 'ontology'; ontology: string; anchor: Uint8Array | null; entity: PrologTerm }
export type WorldMark = { id: string; depicts: Subject | null }
export type MenuEntry = { id: string; label: string; view: string }
export function readPersonalLobby(identity: SignedIdentity, agent: AgentReference, mode?: string): Promise<{ reference: { namespace: string; anchor: Uint8Array }; marks: WorldMark[]; height: number; modes: string[] } | null>
export function readDeviceMenu(identity: SignedIdentity, agent: AgentReference, subject: Subject): Promise<MenuEntry[]>
export function readEntityEidolons(identity: SignedIdentity, agent: AgentReference, subject: Subject): Promise<EidolonChoice[]>
export function readEidolonWorkspace(identity: SignedIdentity, agent: AgentReference, subject: Subject, choice: EidolonChoice): Promise<EidolonWorkspace>
