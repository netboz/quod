import { SIGNED_GOAL_LIMITS, utf8ByteLength } from './protocol-limits.js'

const STORAGE_KEY = 'quod.agent-references.v2'
const LEGACY_STORAGE_KEY = 'quod.agent-references.v1'

export function agentReferences(network) {
  network = validNetwork(network)
  return readRows().filter(row => row.network === network)
}

export function activeAgentReference(network) {
  network = validNetwork(network)
  const state = readState()
  return state.rows.find(row => row.network === network && row.id === state.active[network]) || null
}

export function saveAgentReference(agent) {
  const row = normalizeAgentReference(agent)
  const state = readState()
  const rows = [...state.rows.filter(existing => existing.id !== row.id), row]
  writeState({ active: { ...state.active, [row.network]: row.id }, rows })
  return row
}

export function selectAgentReference(id, network) {
  network = validNetwork(network)
  const state = readState()
  if (!state.rows.some(row => row.network === network && row.id === id)) {
    throw new Error('unknown agent reference')
  }
  writeState({ ...state, active: { ...state.active, [network]: id } })
}

export function removeAgentReference(id) {
  const state = readState()
  const removed = state.rows.find(row => row.id === id)
  const rows = state.rows.filter(row => row.id !== id)
  if (!removed || state.active[removed.network] !== id) {
    writeState({ rows, active: state.active })
    return
  }
  const replacement = rows.find(row => row.network === removed.network)?.id || null
  writeState({ rows, active: { ...state.active, [removed.network]: replacement } })
}

export function normalizeAgentReference(agent) {
  const namespace = agent?.namespace?.trim()
  const anchor = agent?.anchor?.trim()
  const instanceText = agent?.instanceText?.trim()
  const network = validNetwork(agent?.network)
  if (!namespace || utf8ByteLength(namespace) > SIGNED_GOAL_LIMITS.namespaceBytes ||
      !/^[A-Za-z0-9_-]{43}$/.test(anchor || '') ||
      !instanceText ||
      utf8ByteLength(instanceText) > SIGNED_GOAL_LIMITS.agentInstanceTextBytes) {
    throw new Error('invalid agent reference')
  }
  const id = `${network}\0${namespace}\0${anchor}\0${instanceText}`
  return Object.freeze({ id, network, namespace, anchor, instanceText })
}

function readRows() {
  return readState().rows
}

function readState() {
  localStorage.removeItem(LEGACY_STORAGE_KEY)
  let decoded
  try {
    decoded = JSON.parse(localStorage.getItem(STORAGE_KEY) || '{"active":{},"rows":[]}')
  } catch {
    throw new Error('saved agent references are damaged')
  }
  if (!decoded || !Array.isArray(decoded.rows) || !decoded.active ||
      typeof decoded.active !== 'object' || Array.isArray(decoded.active)) {
    throw new Error('saved agent references are damaged')
  }
  let rows
  try {
    rows = decoded.rows.map(normalizeAgentReference)
  } catch {
    throw new Error('saved agent references are damaged')
  }
  const active = Object.fromEntries(Object.entries(decoded.active).filter(
    ([network, id]) => /^[A-Za-z0-9_-]{43}$/.test(network) &&
      (typeof id === 'string' || id === null),
  ))
  return { rows, active }
}

function writeState(state) {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(state))
}

function validNetwork(network) {
  if (!/^[A-Za-z0-9_-]{43}$/.test(network || '')) throw new Error('invalid network identity')
  return network
}
