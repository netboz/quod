// Layout + wiring: header (brand, namespace switcher, search, live dot), stat cards,
// the live table, the detail drawer, and the prove console.

import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useState } from 'react'
import { fetchBlock, fetchSummary, fetchTx, fetchTxs } from './api'
import type { Block, NsSummary } from './api'
import { Console } from './Console'
import { ControlDetail } from './ControlDetail'
import { addHistory, mergeFull, replaceHistory, startWs, useExplorerStore } from './store'
import type { LiveTx } from './store'
import { TxDetail } from './TxDetail'
import { TxTable } from './TxTable'

export default function App() {
  const store = useExplorerStore()
  const qc = useQueryClient()
  const summary = useQuery({ queryKey: ['summary'], queryFn: fetchSummary })
  const [ns, setNs] = useState<string | null>(null)
  const [selected, setSelected] = useState<LiveTx | null>(null)
  const [selectedControl, setSelectedControl] = useState<{ ns: string; block: Block } | null>(null)
  const [loadingMore, setLoadingMore] = useState(false)

  useEffect(() => startWs(), [])

  // hello / sync frames say the node-side picture moved — refetch the summary
  useEffect(() => {
    void qc.invalidateQueries({ queryKey: ['summary'] })
  }, [store.generation, qc])

  const namespaces = useMemo(() => summary.data?.namespaces ?? [], [summary.data])
  const current = ns ?? namespaces[0]?.ns ?? null
  const nsInfo = namespaces.find((n) => n.ns === current) ?? null

  // A hello/sync frame means this browser may have missed block frames. Include its generation in
  // the query key so React Query retries and deduplicates a fresh durable-ledger window instead of
  // leaving a permanent gap after reconnecting.
  const firstPage = useQuery({
    queryKey: ['txs', current, store.generation],
    queryFn: () => fetchTxs(current as string),
    enabled: !!current,
  })
  useEffect(() => {
    if (current && firstPage.data) {
      replaceHistory(current, firstPage.data.txs, firstPage.data.next_before, firstPage.data.height)
    }
  }, [current, firstPage.data])

  const rows = current ? (store.rows[current] ?? []) : []
  const nextBefore = current ? store.nextBefore[current] : null
  // A fetched detail is immutable ledger state. A live selection keeps
  // following the store through its pending → applied/rejected transition.
  const selectedRows = selected ? (store.rows[selected.ns] ?? []) : []
  const selectedStoreRow = selected ? selectedRows.find((tx) => tx.tx_id === selected.tx_id) : null
  const selectedCurrent = selected
    ? !selected.live
      ? selected
      : selectedStoreRow ?? selected
    : null

  const loadMore = async () => {
    if (!current || !nextBefore || loadingMore) return
    setLoadingMore(true)
    try {
      const p = await fetchTxs(current, nextBefore)
      addHistory(current, p.txs, p.next_before, p.height)
    } finally {
      setLoadingMore(false)
    }
  }

  return (
    <div className="mx-auto flex min-h-screen max-w-7xl flex-col px-4 pb-8">
      <Header
        namespaces={namespaces}
        current={current}
        onNs={(n) => {
          setNs(n)
          setSelected(null)
          setSelectedControl(null)
        }}
        ws={store.ws}
        onFound={(tx) => {
          setSelectedControl(null)
          setSelected(tx)
        }}
        onControl={(block) => {
          setSelected(null)
          setSelectedControl(current ? { ns: current, block } : null)
        }}
      />
      {nsInfo && <StatCards info={nsInfo} liveHeight={store.heights[nsInfo.ns] ?? nsInfo.height} />}
      <main className="mt-4 flex flex-1 flex-col gap-4 lg:flex-row lg:items-start">
        <div className="min-w-0 flex-1 space-y-4">
          {current && <Console ns={current} />}
          {firstPage.isError && rows.length === 0 && (
            <div className="flex items-center justify-between rounded-xl border border-rose/30 bg-rose/5 px-4 py-2.5 text-sm text-rose">
              <span>Couldn't load transaction history.</span>
              <button onClick={() => void firstPage.refetch()} className="rounded-lg px-3 py-1 font-medium hover:bg-rose/10">
                Retry
              </button>
            </div>
          )}
          <TxTable
            rows={rows}
            selected={selectedCurrent?.tx_id ?? null}
            onSelect={setSelected}
            hasMore={nextBefore != null}
            onMore={() => void loadMore()}
            loadingMore={loadingMore}
          />
        </div>
        {selectedCurrent && (
          <div className="w-full lg:sticky lg:top-4 lg:w-[26rem] lg:shrink-0">
            <TxDetail tx={selectedCurrent} onClose={() => setSelected(null)} />
          </div>
        )}
        {selectedControl && (
          <div className="w-full lg:sticky lg:top-4 lg:w-[26rem] lg:shrink-0">
            <ControlDetail ns={selectedControl.ns} block={selectedControl.block} onClose={() => setSelectedControl(null)} />
          </div>
        )}
      </main>
    </div>
  )
}

function Header({
  namespaces,
  current,
  onNs,
  ws,
  onFound,
  onControl,
}: {
  namespaces: NsSummary[]
  current: string | null
  onNs: (ns: string) => void
  ws: 'connecting' | 'live' | 'down'
  onFound: (tx: LiveTx) => void
  onControl: (block: Block) => void
}) {
  return (
    <header className="-mx-4 mb-4 bg-teal px-4 text-cream shadow-md">
      <div className="mx-auto flex max-w-7xl flex-wrap items-center gap-x-6 gap-y-2 py-3">
        <div className="flex items-center gap-2.5">
          <img src="favicon.png" alt="" className="h-8 w-8" />
          <h1 className="text-lg font-semibold tracking-tight">
            quod <span className="text-gold">∴</span> explorer
          </h1>
        </div>
        <nav className="flex gap-1">
          {namespaces.map((n) => (
            <button
              key={n.ns}
              onClick={() => onNs(n.ns)}
              className={
                'rounded-lg px-3 py-1 font-mono text-sm transition ' +
                (n.ns === current ? 'bg-gold font-semibold text-teal' : 'text-cream/80 hover:bg-teal-light')
              }
            >
              {n.ns}
              {n.syncing && <span className="ml-1.5 text-[10px] text-gold-soft">syncing</span>}
            </button>
          ))}
        </nav>
        <div className="ml-auto flex items-center gap-4">
          {current && <Search ns={current} onFound={onFound} onControl={onControl} />}
          <span className="flex items-center gap-1.5 text-xs">
            <span
              className={
                'inline-block h-2 w-2 rounded-full ' +
                (ws === 'live' ? 'bg-olive-light' : ws === 'connecting' ? 'bg-gold' : 'bg-rose-light')
              }
            />
            {ws === 'live' ? 'live' : ws === 'connecting' ? 'connecting…' : 'reconnecting…'}
          </span>
        </div>
      </div>
    </header>
  )
}

function Search({ ns, onFound, onControl }: { ns: string; onFound: (tx: LiveTx) => void; onControl: (block: Block) => void }) {
  const [q, setQ] = useState('')
  const [state, setState] = useState<'idle' | 'busy' | 'miss' | 'empty' | 'pending'>('idle')
  const [pendingRef, setPendingRef] = useState<{ anchor: string; tx_id: string } | null>(null)

  const found = (tx: LiveTx) => {
    onFound(tx)
    setState('idle')
    setPendingRef(null)
    setQ('')
  }

  const go = async () => {
    const query = q.trim()
    if (!query) return
    setState('busy')
    try {
      // All-digit AND short → a block height; a tx id hex is 24 chars (so an all-digit id isn't mistaken
      // for a height). A height loads the whole block: every tx is merged into the list (not just the
      // first), and the first is opened. A DTX control opens its control detail; a skip reports 'empty'.
      if (/^\d+$/.test(query) && query.length < 16) {
        const b = await fetchBlock(ns, Number(query))
        if (!('error' in b)) {
          if (b.txs.length === 0) {
            if (b.control) {
              onControl(b)
              return foundControl()
            }
            return setState('empty')
          }
          mergeFull(ns, b.txs, b.cert)
          return found({ ...b.txs[0], status: 'history', cert: b.cert, live: false })
        }
      } else {
        const r = await fetchTx(ns, query)
        if (!('error' in r)) {
          if (!('tx' in r)) {
            setPendingRef(r.outcome)
            return setState('pending')
          }
          const status = r.outcome.status === 'rejected' ? 'rejected' : 'applied'
          return found({ ...r.tx, status, cert: r.block.cert, live: false })
        }
      }
      setState('miss')
    } catch {
      setState('miss')
    }
  }

  const foundControl = () => {
    setState('idle')
    setQ('')
  }

  return (
    <div className="relative">
      <input
        value={q}
        onChange={(e) => {
          setQ(e.target.value)
          setState('idle')
          setPendingRef(null)
        }}
        onKeyDown={(e) => e.key === 'Enter' && void go()}
        placeholder="tx id or height…"
        spellCheck={false}
        className={
          'w-52 rounded-lg border bg-teal-dark px-3 py-1.5 font-mono text-xs text-cream placeholder:text-gray focus:ring-2 focus:ring-gold/50 focus:outline-none ' +
          (state === 'miss' ? 'border-rose' : 'border-teal-light/50')
        }
      />
      {state === 'busy' && <span className="absolute top-1.5 right-2 text-xs text-gray">…</span>}
      {state === 'miss' && <span className="absolute top-1.5 right-2 text-xs text-rose-light">not found</span>}
      {state === 'empty' && <span className="absolute top-1.5 right-2 text-xs text-gray">empty block</span>}
      {state === 'pending' && <span className="absolute top-1.5 right-2 text-xs text-gold">pending</span>}
      {state === 'pending' && pendingRef && (
        <div
          className="absolute top-full right-0 z-10 mt-1 rounded-md bg-teal-dark px-2 py-1 font-mono text-[10px] whitespace-nowrap text-gold-soft shadow"
          title={`transaction:${ns}:${pendingRef.anchor}:${pendingRef.tx_id}`}
        >
          anchor {pendingRef.anchor.slice(0, 10)}… · tx {pendingRef.tx_id.slice(0, 12)}…
        </div>
      )}
    </div>
  )
}

function StatCards({ info, liveHeight }: { info: NsSummary; liveHeight: number }) {
  return (
    <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
      <Card label="Committed height" value={`#${Math.max(liveHeight, info.height)}`} tone="border-teal-light" />
      <Card label="Applied locally" value={`#${info.applied}`} tone="border-olive" />
      <Card label="Committee" value={String(info.committee.length)} sub={info.role} tone="border-gold" />
      <Card
        label={info.proposal_open ? 'Next proposer' : 'Finality leader'}
        value={
          (info.proposal_open ? info.next_proposer?.id : info.finality_leader?.id) ?? '—'
        }
        mono
        sub={
          info.syncing
            ? 'syncing'
            : info.proposal_open
              ? `slot #${info.proposal_slot}`
              : `${info.progress_phase.replaceAll('_', ' ')} · finality #${info.finality_slot}`
        }
        title={
          info.proposal_open
            ? `Validator responsible for proposing slot ${info.proposal_slot}`
            : `Waiting for slot ${info.finality_slot}; its leader is ${info.finality_leader?.id ?? 'unknown'}`
        }
        tone="border-teal"
      />
      <Card
        label="Genesis anchor"
        value={info.genesis ? info.genesis.slice(0, 10) + '…' : '—'}
        mono
        title={info.genesis ?? undefined}
        tone="border-rose"
      />
    </div>
  )
}

function Card({
  label,
  value,
  sub,
  mono,
  title,
  tone,
}: {
  label: string
  value: string
  sub?: string
  mono?: boolean
  title?: string
  tone: string
}) {
  return (
    <div className={`rounded-xl border border-gray/35 border-t-4 bg-white/90 px-4 py-3 shadow-sm ${tone}`} title={title}>
      <div className="text-[11px] tracking-wider text-gray uppercase">{label}</div>
      <div className={'mt-1 text-lg font-semibold text-teal ' + (mono ? 'font-mono text-base' : '')}>{value}</div>
      {sub && <div className="text-[11px] text-gray">{sub}</div>}
    </div>
  )
}
