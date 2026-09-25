import type { SignedIdentity, AgentReference } from './signed-client.js'
export type ProofView = { title: string; goal: string; results: string; run: string; next: string; accept: string; stop: string }
export function anchoredGoal(reference: { namespace: string; anchor: Uint8Array }, goal: unknown): string
export function readProofView(binding: string): ProofView
export function singleBinding(reply: Record<string, unknown>, name: string): string
export function readAgentReference(binding: string): { namespace: string; anchor: string; instanceText: string }
export function readReference(binding: string): { namespace: string; anchor: Uint8Array }
import type { PrologTerm } from './prolog-term.js'
export type Subject = { ontology: string; anchor: Uint8Array | null; entity: PrologTerm }
export type WorldMark = { id: string; depicts: Subject | null }
export type MenuEntry = { id: string; label: string; view: string }
export function readPersonalLobby(identity: SignedIdentity, agent: AgentReference, mode?: string): Promise<{ reference: { namespace: string; anchor: Uint8Array }; marks: WorldMark[]; height: number } | null>
export function readDeviceMenu(identity: SignedIdentity, agent: AgentReference, subject: Subject): Promise<MenuEntry[]>
