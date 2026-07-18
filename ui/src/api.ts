// Types mirroring quod_explorer_http's JSON, plus thin fetch helpers.

export type PeerId = { id: string; pubkey: string | null }

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
}

export type Op = { op: 'assert' | 'retract' | 'unknown'; clause: string }

export type TxFull = TxRow & {
  result: Record<string, string> | Record<string, string>[] | string | null
  diff: Op[]
  read_predicates: number
  signature: string | null
  signature_status: 'verified' | 'genesis' | 'unsigned' | 'invalid' | 'unknown'
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
  progress_quorum_connected: boolean
  genesis: string | null
}

export type Summary = { node: PeerId | null; namespaces: NsSummary[] }

export type TxsPage = { txs: TxRow[]; height: number; next_before: number | null }

export type Block = {
  slot: number
  time: number
  noop: boolean
  cert: Cert
  txs: TxFull[]
}

export type FoundTx = { tx: TxFull; block: { slot: number; time: number; noop: boolean; cert: Cert } }

export type ProveReply =
  | { result: 'ok'; height: number; bindings: Record<string, string>[] }
  | { result: 'fail' }
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
  get<FoundTx | { error: string }>(`api/tx/${encodeURIComponent(ns)}/${encodeURIComponent(id)}`)

export const prove = async (ns: string, goal: string): Promise<ProveReply> => {
  const r = await fetch('api/prove', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ ns, goal }),
  })
  return (await r.json()) as ProveReply
}
