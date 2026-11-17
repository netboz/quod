import type { SignedIdentity, AgentReference } from './signed-client.js'
import type { WorldMark } from './world.js'
export function readLensView(identity: SignedIdentity, agent: AgentReference, lens: string, parameters: string[]): Promise<{ height: number; marks?: WorldMark[]; unmet?: string[] }>
