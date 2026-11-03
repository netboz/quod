export type StoredAgentReference = Readonly<{
  id: string
  network: string
  namespace: string
  anchor: string
  instanceText: string
}>

export function agentReferences(network: string): StoredAgentReference[]
export function activeAgentReference(network: string): StoredAgentReference | null
export function saveAgentReference(agent: {
  network: string
  namespace: string
  anchor: string
  instanceText: string
}): StoredAgentReference
export function selectAgentReference(id: string, network: string): void
export function removeAgentReference(id: string): void
export function normalizeAgentReference(agent: {
  network: string
  namespace: string
  anchor: string
  instanceText: string
}): StoredAgentReference
