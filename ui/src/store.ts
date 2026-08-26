// The live transaction store + WebSocket wiring.
//
// Rows come from two places and meet here:
//  - history pages (GET /api/txs) — status "history": committed fact, apply outcome not recorded;
//  - live `block` WS frames — status "pending" until the matching explicit `applied` or `rejected`
//    outcome arrives.
//
// One module-level store, consumed via useSyncExternalStore — no state library needed.

import { useSyncExternalStore } from 'react'
import type { Block, Cert, ControlRow, LedgerRow, TxFull } from './api'

export type TxStatus = 'history' | 'pending' | 'applied' | 'rejected'

export type LiveTx = TxFull & {
  status: TxStatus
  cert: Cert
  live: boolean // arrived over the socket during this session (has full detail + flash)
}

export type LiveControl = ControlRow & {
  cert: Cert
  live: boolean
}

export type LiveLedgerRow = LiveTx | LiveControl

export type WsState = 'connecting' | 'live' | 'down'

type State = {
  ws: WsState
  rows: Record<string, LiveLedgerRow[]> // per namespace, newest first
  nextBefore: Record<string, number | null | undefined> // history paging cursor
  heights: Record<string, number>
  generation: number // bumped on `hello`/`sync` — consumers refetch the summary
}

let state: State = { ws: 'connecting', rows: {}, nextBefore: {}, heights: {}, generation: 0 }
const listeners = new Set<() => void>()

function emit(next: Partial<State>) {
  state = { ...state, ...next }
  listeners.forEach((l) => l())
}

export function useExplorerStore(): State {
  return useSyncExternalStore(
    (cb) => (listeners.add(cb), () => listeners.delete(cb)),
    () => state,
  )
}

const asHistory = (t: LedgerRow): LiveLedgerRow => {
  if (t.row_type === 'control') return { ...t, cert: null, live: false }
  return {
  result: null,
  diff: [],
  root_facts_changed: t.fact_ops > 0,
  effects: [],
  read_predicates: 0,
  origin: null,
  proof_id: null,
  plan_digest: null,
  signature: null,
  signature_status: 'unknown',
  ...t,
  status: 'history',
  cert: null,
  live: false,
  }
}

// Merge already-rendered ledger records (from a block fetch / height search) as rows, keeping any
// existing live transaction status. Returns the deduplicated, height-sorted list.
function mergeRows(existing: LiveLedgerRow[], fresh: LiveLedgerRow[]): LiveLedgerRow[] {
  const have = new Set(existing.map((t) => t.row_id))
  return [...existing, ...fresh.filter((t) => !have.has(t.row_id))]
    .sort((a, b) => b.height - a.height)
}

export function addHistory(ns: string, txs: LedgerRow[], nextBefore: number | null, height: number) {
  emit({
    rows: { ...state.rows, [ns]: mergeRows(state.rows[ns] ?? [], txs.map(asHistory)) },
    nextBefore: { ...state.nextBefore, [ns]: nextBefore },
    heights: { ...state.heights, [ns]: Math.max(height, state.heights[ns] ?? 0) },
  })
}

// A new WebSocket session (or a local replay boundary) has no resumable cursor. Merge its newest
// durable-ledger window and move the paging cursor behind it, so subsequent paging bridges any gap
// without discarding history the user already loaded. A pending row within the durable view belonged
// to the socket session that just ended, so reset it until a new explicit outcome arrives.
export function replaceHistory(ns: string, txs: LedgerRow[], nextBefore: number | null, height: number) {
  const existing = state.rows[ns] ?? []
  const reconciled = existing.map((t): LiveLedgerRow =>
    t.row_type === 'transaction' && t.status === 'pending' && t.height <= height
      ? { ...t, status: 'history', live: false }
      : t,
  )
  emit({
    rows: { ...state.rows, [ns]: mergeRows(reconciled, txs.map(asHistory)) },
    nextBefore: { ...state.nextBefore, [ns]: nextBefore },
    heights: { ...state.heights, [ns]: Math.max(height, state.heights[ns] ?? 0) },
  })
}

// Merge full txs (e.g. from a height search) without touching the paging cursor.
export function mergeFull(ns: string, txs: TxFull[], cert: Cert) {
  const fresh = txs.map((t): LiveTx => ({ ...t, status: 'history', cert, live: false }))
  emit({ rows: { ...state.rows, [ns]: mergeRows(state.rows[ns] ?? [], fresh) } })
}

function isDtxPhase(kind: Block['kind']): kind is ControlRow['phase'] {
  return kind === 'begin' || kind === 'prepare' || kind === 'decision' || kind === 'finalize' || kind === 'complete'
}

function addBlock(ns: string, block: Block) {
  const existing = state.rows[ns] ?? []
  const have = new Set(existing.map((t) => t.row_id))
  const fresh: LiveLedgerRow[] = block.kind === 'content'
    ? block.txs
        .filter((t) => !have.has(t.row_id))
        .map((t): LiveTx => ({ ...t, status: 'pending', cert: block.cert, live: true }))
    : block.control && isDtxPhase(block.kind)
      ? [{
          row_type: 'control',
          row_id: `dtx:${block.control.record_digest}`,
          ns,
          height: block.slot,
          time: block.time,
          phase: block.kind,
          control: block.control,
          cert: block.cert,
          live: true,
        }]
      : []
  const rows = mergeRows(existing, fresh)
  emit({
    rows: { ...state.rows, [ns]: rows },
    heights: { ...state.heights, [ns]: Math.max(block.slot, state.heights[ns] ?? 0) },
  })
}

// The apply outcome arrives explicitly per tx (applied_live / rejected_live) — no inference.
function markOutcome(ns: string, txId: string, status: 'applied' | 'rejected') {
  const rows = (state.rows[ns] ?? []).map((t): LiveLedgerRow =>
    t.row_type === 'transaction' && t.tx_id === txId ? { ...t, status } : t,
  )
  emit({ rows: { ...state.rows, [ns]: rows } })
}

// --- WebSocket ---------------------------------------------------------------

type Frame =
  | { type: 'hello' }
  | ({ type: 'block'; ns: string } & Block)
  | { type: 'applied'; ns: string; height: number; tx_id: string }
  | { type: 'rejected'; ns: string; height: number; tx_id: string }
  | { type: 'sync' }

let started = false

export function startWs() {
  if (started) return
  started = true
  connect()
}

function connect() {
  emit({ ws: 'connecting' })
  const proto = location.protocol === 'https:' ? 'wss://' : 'ws://'
  const sock = new WebSocket(proto + location.host + location.pathname.replace(/\/$/, '') + '/ws')
  sock.onopen = () => emit({ ws: 'live' })
  sock.onclose = () => {
    emit({ ws: 'down' })
    setTimeout(connect, 1500)
  }
  sock.onmessage = (m) => {
    const f = JSON.parse(m.data) as Frame
    switch (f.type) {
      case 'hello':
      case 'sync':
        emit({ generation: state.generation + 1 })
        break
      case 'block':
        addBlock(f.ns, f)
        break
      case 'applied':
        markOutcome(f.ns, f.tx_id, 'applied')
        break
      case 'rejected':
        markOutcome(f.ns, f.tx_id, 'rejected')
        break
    }
  }
}
