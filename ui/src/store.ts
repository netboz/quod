// The live transaction store + WebSocket wiring.
//
// Rows come from two places and meet here:
//  - history pages (GET /api/txs) — status "history": committed fact, apply outcome not recorded;
//  - live `block` WS frames — status "pending" until the matching explicit `applied` or `rejected`
//    outcome arrives.
//
// One module-level store, consumed via useSyncExternalStore — no state library needed.

import { useSyncExternalStore } from 'react'
import type { Cert, TxFull, TxRow } from './api'

export type TxStatus = 'history' | 'pending' | 'applied' | 'rejected'

export type LiveTx = TxFull & {
  status: TxStatus
  cert: Cert
  live: boolean // arrived over the socket during this session (has full detail + flash)
}

export type WsState = 'connecting' | 'live' | 'down'

type State = {
  ws: WsState
  rows: Record<string, LiveTx[]> // per namespace, newest first, capped
  nextBefore: Record<string, number | null | undefined> // history paging cursor
  heights: Record<string, number>
  generation: number // bumped on `hello`/`sync` — consumers refetch the summary
}

// Bounds rows[ns] so a busy chain can't grow it without limit. Applied on EVERY mutation
// (history and live) so a new live block can never silently drop rows the user just paged in —
// it only ever trims the oldest beyond CAP, symmetrically.
const CAP = 2000

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

const asHistory = (t: TxRow): LiveTx => ({
  result: null,
  diff: [],
  read_predicates: 0,
  ...t,
  status: 'history',
  cert: null,
  live: false,
})

// Merge already-rendered full transactions (from a block fetch / height search) as rows, keeping any
// existing live status. Returns the deduped, height-sorted, capped list.
function mergeRows(existing: LiveTx[], fresh: LiveTx[]): LiveTx[] {
  const have = new Set(existing.map((t) => t.tx_id))
  return [...existing, ...fresh.filter((t) => !have.has(t.tx_id))]
    .sort((a, b) => b.height - a.height)
    .slice(0, CAP)
}

export function addHistory(ns: string, txs: TxRow[], nextBefore: number | null, height: number) {
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
export function replaceHistory(ns: string, txs: TxRow[], nextBefore: number | null, height: number) {
  const existing = state.rows[ns] ?? []
  const reconciled = existing.map((t): LiveTx =>
    t.status === 'pending' && t.height <= height ? { ...t, status: 'history', live: false } : t,
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

function addBlock(ns: string, txs: TxFull[], cert: Cert, slot: number) {
  const have = new Set((state.rows[ns] ?? []).map((t) => t.tx_id))
  const fresh = txs
    .filter((t) => !have.has(t.tx_id))
    .map((t): LiveTx => ({ ...t, status: 'pending', cert, live: true }))
  // newest first, then bound — trims only the oldest tail, never the rows just prepended
  const rows = [...fresh, ...(state.rows[ns] ?? [])].slice(0, CAP)
  emit({
    rows: { ...state.rows, [ns]: rows },
    heights: { ...state.heights, [ns]: Math.max(slot, state.heights[ns] ?? 0) },
  })
}

// The apply outcome arrives explicitly per tx (applied_live / rejected_live) — no inference.
function markOutcome(ns: string, txId: string, status: 'applied' | 'rejected') {
  const rows = (state.rows[ns] ?? []).map((t): LiveTx => (t.tx_id === txId ? { ...t, status } : t))
  emit({ rows: { ...state.rows, [ns]: rows } })
}

// --- WebSocket ---------------------------------------------------------------

type Frame =
  | { type: 'hello' }
  | { type: 'block'; ns: string; slot: number; time: number; cert: Cert; txs: TxFull[] }
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
        addBlock(f.ns, f.txs, f.cert, f.slot)
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
