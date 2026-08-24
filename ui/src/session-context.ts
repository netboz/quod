import { createContext, useContext } from 'react'
import type { SignedIdentity } from '../../client/src/signed-client.js'
import type { AgentReference } from '../../client/src/signed-client.js'

export type SessionState = {
  identity: SignedIdentity | null
  agent: AgentReference | null
  busy: boolean
  saved: boolean
  unresolved: number
  error: string | null
  create: () => Promise<void>
  unlock: () => Promise<void>
  save: () => Promise<void>
  exportKey: () => Promise<void>
  signOut: () => Promise<void>
  addAgent: () => void
  selectAgent: (id: string) => void
  agents: (AgentReference & { id: string })[]
}

export const SessionContext = createContext<SessionState | null>(null)

export function useSignedSession() {
  const state = useContext(SessionContext)
  if (!state) throw new Error('SignedSessionProvider is missing')
  return state
}
