import { SIGNED_GOAL_LIMITS, utf8ByteLength } from './protocol-limits.js'

const STORAGE_KEY = 'quod.agent-references.v1'

export function agentReferences() {
  return readRows()
}

export function activeAgentReference() {
  const state = readState()
  return state.rows.find(row => row.id === state.active) || null
}

export function saveAgentReference(agent) {
  const row = normalized(agent)
  const state = readState()
  const rows = [...state.rows.filter(existing => existing.id !== row.id), row]
  writeState({ active: row.id, rows })
  return row
}

export function selectAgentReference(id) {
  const state = readState()
  if (!state.rows.some(row => row.id === id)) throw new Error('unknown agent reference')
  writeState({ ...state, active: id })
}

export function removeAgentReference(id) {
  const state = readState()
  const rows = state.rows.filter(row => row.id !== id)
  writeState({ rows, active: state.active === id ? (rows[0]?.id || null) : state.active })
}

function normalized(agent) {
  const namespace = agent?.namespace?.trim()
  const anchor = agent?.anchor?.trim()
  const instanceText = agent?.instanceText?.trim()
  if (!namespace || utf8ByteLength(namespace) > SIGNED_GOAL_LIMITS.namespaceBytes ||
      !/^[A-Za-z0-9_-]{43}$/.test(anchor || '') ||
      !instanceText ||
      utf8ByteLength(instanceText) > SIGNED_GOAL_LIMITS.agentInstanceTextBytes) {
    throw new Error('invalid agent reference')
  }
  const id = `${namespace}\0${anchor}\0${instanceText}`
  return Object.freeze({ id, namespace, anchor, instanceText })
}

function readRows() {
  return readState().rows
}

function readState() {
  let decoded
  try {
    decoded = JSON.parse(localStorage.getItem(STORAGE_KEY) || '{"active":null,"rows":[]}')
  } catch {
    throw new Error('saved agent references are damaged')
  }
  if (!decoded || !Array.isArray(decoded.rows)) {
    throw new Error('saved agent references are damaged')
  }
  const rows = decoded.rows.map(normalized)
  const active = typeof decoded.active === 'string' ? decoded.active : null
  return { rows, active }
}

function writeState(state) {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(state))
}
