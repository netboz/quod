// Types mirroring quod_explorer_http's JSON, plus thin fetch helpers.

import { signedCursorCommand, signedGoal } from '../../client/src/signed-client.js'
import type { SignedIdentity } from '../../client/src/signed-client.js'

export type PeerId = { id: string; pubkey: string | null }
export type Origin = { ns: string; anchor: string } | null

export type TxRow = {
  tx_id: string
  ns: string
  height: number
  time: number // block timestamp, ms epoch (0 = genesis/unset)
  goal: string | null // Prolog text; null = genesis
  author: PeerId | null
  author_seq: number
  submitted_at: number // ms epoch, 0 = unset
  ops: number
  fact_ops: number
  effect_count: number
  effect_operations: string[]
}

export type Op =
  | { op: 'assert' | 'retract'; clause: string }
  | { op: 'event'; term: string }

export type Effect = {
  effect_id: string
  operation: string
  executor: PeerId
  actor: { kind: 'node' | 'user'; identity: PeerId }
  actor_authority: 'author_node_claimed'
  target: { ns: string; anchor: string }
  request_digest: string
  prepared_digest: string
  local_execution: 'pending' | 'applied' | 'retired' | 'operator_error' | 'unavailable' | 'not_this_node'
  local_execution_height?: number
  local_execution_result?: string | null
}

export type TxFull = TxRow & {
  result: Record<string, string> | Record<string, string>[] | string | null
  diff: Op[]
  root_facts_changed: boolean
  effects: Effect[]
  read_predicates: number
  origin: Origin
  proof_id: string | null
  plan_digest: string | null
  request?: SignedRequest | null
  signature: string | null
  signature_status: 'verified' | 'genesis' | 'unsigned' | 'invalid' | 'unknown'
}

export type SignedRequest = {
  status: 'verified' | 'invalid'
  request_digest: string | null
  user: PeerId | null
  operation_id: string | null
  operation_ref: {
    kind: 'operation'
    ns: string
    anchor: string
    user: PeerId
    operation_id: string
  } | null
  target: Origin
  mode: 'execute' | 'cursor' | null
  parser_version: number | null
  not_after_ms: number | null
  signature: string | null
  first_outcome: {
    kind: 'transaction' | 'group'
    ns: string
    anchor: string
    tx_id?: string
    coordinator?: PeerId
    coordinator_admission?: string
    group_id?: string
  } | null
}

export type Cert = {
  kind: string
  signers: PeerId[]
  child_slot?: number
} | null

export type NsSummary = {
  ns: string
  height: number
  applied: number
  role: string
  syncing: boolean
  committee: PeerId[]
  approved: number
  finality_slot: number
  finality_leader: PeerId | null
  proposal_slot: number
  next_proposer: PeerId | null
  proposal_open: boolean
  progress_phase: 'idle' | 'awaiting_proposal' | 'awaiting_notarization' | 'awaiting_commit'
  progress_quorum_ready: boolean
  genesis: string | null
}

export type Summary = { node: PeerId | null; namespaces: NsSummary[] }

export type TxsPage = { txs: TxRow[]; height: number; next_before: number | null }

export type Block = {
  slot: number
  time: number
  kind: 'content' | 'begin' | 'prepare' | 'decision' | 'finalize' | 'complete' | 'noop' | 'invalid'
  cert: Cert
  txs: TxFull[]
  control?: Control
}

export type Control = {
  kind: 'begin' | 'prepare' | 'decision' | 'finalize' | 'complete'
  group_id: string
  record_digest: string
  target: Origin
  author: PeerId
  author_admission: string
  sequence: number
  submitted_at: number
  participant_count?: number
  request?: SignedRequest | null
  plan_digest?: string
  verdict?: 'commit' | 'abort'
  prepare_count?: number
  reasons?: string[] | null
  prepared?: boolean
  applied_generation?: number
  finalize_count?: number
}

export type TxOutcome = {
  status: 'pending' | 'committed' | 'rejected'
  ns: string
  anchor: string
  tx_id: string
  goal?: string
  bindings?: Record<string, string>
  height?: number
  reason?: string
}

export type FoundTx = {
  tx: TxFull
  block: { slot: number; time: number; noop: boolean; cert: Cert }
  outcome: TxOutcome
}

export type FoundOutcome = FoundTx | { outcome: TxOutcome }

export type ProveReply =
  | { result: 'solution'; cursor: string; height: number; bindings: Record<string, string>[] }
  | { result: 'ok'; height: number; bindings: Record<string, string>[] }
  | { result: 'ok'; ns: string; anchor: string; tx_id: string; bindings: Record<string, string>[] }
  | {
      result: 'ok'
      ns: string
      anchor: string
      coordinator: string
      coordinator_admission: string
      group_id: string
      height: number
      participant_slots: { ns: string; anchor: string; height: number; generation: number }[]
      bindings: Record<string, string>[]
    }
  | { result: 'fail'; reasons?: string[] }
  | { result: 'pending'; ns: string; anchor: string; tx_id: string }
  | {
      result: 'pending'
      ns: string
      anchor: string
      coordinator: string
      coordinator_admission: string
      group_id: string
    }
  | { result: 'stopped' }
  | { error: string; detail?: string; leader?: PeerId | null }

async function get<T>(url: string): Promise<T> {
  const r = await fetch(url)
  if (!r.ok && r.headers.get('content-type')?.includes('json')) return (await r.json()) as T
  if (!r.ok) throw new Error(`${r.status} ${r.statusText}`)
  return (await r.json()) as T
}

export const fetchSummary = () => get<Summary>('api/summary')

export const fetchTxs = (ns: string, before?: number | null, limit = 50) =>
  get<TxsPage>(
    `api/txs?ns=${encodeURIComponent(ns)}&limit=${limit}` + (before ? `&before=${before}` : ''),
  )

export const fetchBlock = (ns: string, slot: number) =>
  get<Block | { error: string }>(`api/block/${encodeURIComponent(ns)}/${slot}`)

export const fetchTx = (ns: string, id: string) =>
  get<FoundOutcome | { error: string }>(`api/tx/${encodeURIComponent(ns)}/${encodeURIComponent(id)}`)

export const openProofCursor = (
  identity: SignedIdentity,
  ns: string,
  anchor: string,
  goal: string,
) => signedGoal(
  identity,
  { mode: 'cursor', namespace: ns, anchor: hex32(anchor), goal },
) as Promise<ProveReply>

export const nextProofSolution = (identity: SignedIdentity, cursor: string) =>
  signedCursorCommand(identity, cursor, 'next') as Promise<ProveReply>

export const acceptProofSolution = (identity: SignedIdentity, cursor: string) =>
  signedCursorCommand(identity, cursor, 'accept') as Promise<ProveReply>

export const stopProofCursor = (identity: SignedIdentity, cursor: string) =>
  signedCursorCommand(identity, cursor, 'stop') as Promise<ProveReply>

function hex32(value: string) {
  if (!/^[0-9a-fA-F]{64}$/.test(value)) throw new Error('invalid ontology anchor')
  return Uint8Array.from(value.match(/../g)!, (byte) => Number.parseInt(byte, 16))
}
