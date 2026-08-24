export type StoredAgentReference = Readonly<{
  id: string
  namespace: string
  anchor: string
  instanceText: string
}>

export function agentReferences(): StoredAgentReference[]
export function activeAgentReference(): StoredAgentReference | null
export function saveAgentReference(agent: {
  namespace: string
  anchor: string
  instanceText: string
}): StoredAgentReference
export function selectAgentReference(id: string): void
export function removeAgentReference(id: string): void
