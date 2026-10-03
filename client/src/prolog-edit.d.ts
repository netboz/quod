import type { SignedIdentity, AgentReference } from './signed-client.js'
import type { EidolonWorkspace } from './world.js'
import type { PrologTerm } from './prolog-term.js'
export function readCodePredicates(identity: SignedIdentity, agent: AgentReference, workspace: EidolonWorkspace): Promise<PrologTerm[]>
export function readCodeSource(identity: SignedIdentity, agent: AgentReference, workspace: EidolonWorkspace, indicator: PrologTerm): Promise<string>
export function prepareCodeEdit(identity: SignedIdentity, agent: AgentReference, workspace: EidolonWorkspace, indicator: PrologTerm, baseline: string, source: string): Promise<string>
export function predicateIndicator(text: string): PrologTerm
export type ClauseCard = { head: string; body: string }
export function readCodeClauses(identity: SignedIdentity, agent: AgentReference, workspace: EidolonWorkspace, source: string): Promise<ClauseCard[]>
export function clausesSource(clauses: ClauseCard[]): string
