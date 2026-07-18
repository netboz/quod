// The detail drawer: everything known about one transaction. Live rows carry full
// detail already; history rows lazy-load their block for diff/result/cert.

import { useQuery } from '@tanstack/react-query'
import { fetchBlock } from './api'
import type { Cert, Op } from './api'
import type { LiveTx, TxStatus } from './store'
import { shortHex, timestamp } from './format'

const statusText: Record<TxStatus, string> = {
  history: 'committed (apply outcome not recorded in history)',
  pending: 'committed — waiting for local apply',
  applied: 'applied — the kb changed',
  rejected: 'OCC-rejected at apply — the kb did not change',
}

export function TxDetail({ tx, onClose }: { tx: LiveTx; onClose: () => void }) {
  // A history row has no diff/result/cert — read its block (direct by height, no scan).
  const needsBlock = !tx.live && tx.diff.length === 0
  const block = useQuery({
    queryKey: ['block', tx.ns, tx.height],
    queryFn: () => fetchBlock(tx.ns, tx.height),
    enabled: needsBlock,
    staleTime: Infinity, // committed blocks never change
  })

  const full = (() => {
    if (!needsBlock) return { ...tx, cert: tx.cert }
    if (block.data && !('error' in block.data)) {
      const found = block.data.txs.find((t) => t.tx_id === tx.tx_id)
      if (found) return { ...tx, ...found, cert: block.data.cert }
    }
    return tx
  })()

  return (
    <aside className="flex h-full flex-col overflow-y-auto rounded-xl border border-gray/25 bg-white shadow-sm">
      <header className="flex items-center justify-between border-b border-gray/20 bg-teal px-4 py-3 text-cream">
        <div>
          <div className="text-[11px] tracking-wider text-gray uppercase">Transaction</div>
          <div className="font-mono text-sm">{shortHex(full.tx_id, 24)}</div>
        </div>
        <button onClick={onClose} className="rounded-lg px-2 py-1 text-gray hover:bg-teal-light hover:text-cream">
          ✕
        </button>
      </header>

      <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 px-4 py-3 text-sm">
        <Dt>Status</Dt>
        <dd>
          <StatusBadge status={full.status} />
          <span className="ml-2 text-xs text-gray">{statusText[full.status]}</span>
        </dd>
        <Dt>Ontology</Dt>
        <dd className="font-mono">{full.ns}</dd>
        <Dt>Height</Dt>
        <dd className="font-mono text-teal-light">#{full.height}</dd>
        <Dt>Block time</Dt>
        <dd>{timestamp(full.time)}</dd>
        <Dt>Submitted</Dt>
        <dd>{timestamp(full.submitted_at)}</dd>
        <Dt>Author</Dt>
        <dd className="font-mono text-xs break-all">
          {full.author ? (
            <span title={full.author.pubkey ?? undefined}>{full.author.id}</span>
          ) : (
            '—'
          )}
        </dd>
        <Dt>Tx id</Dt>
        <dd className="font-mono text-xs break-all">{full.tx_id}</dd>
        <Dt>Read set</Dt>
        <dd className="text-xs text-gray">{full.read_predicates} predicate(s) checked (OCC)</dd>
      </dl>

      <Section title="Goal">
        <pre className="rounded-lg bg-cream p-3 font-mono text-[13px] break-all whitespace-pre-wrap text-teal">
          {full.goal ?? 'genesis'}
        </pre>
      </Section>

      {full.result != null && (
        <Section title="Result">
          <Bindings result={full.result} />
        </Section>
      )}

      <DiffSection diff={full.diff} status={full.status} loading={block.isLoading} />

      <CertSection cert={full.cert} />
    </aside>
  )
}

// The diff is what the proof PROPOSED. It only actually changed the kb when the tx applied; for a
// pending or rejected tx it is proposed-but-not-applied, so it is shown muted (never green asserts)
// with a note, so the drawer never contradicts a red "rejected / kb did not change" status.
function DiffSection({ diff, status, loading }: { diff: Op[]; status: TxStatus; loading: boolean }) {
  const applied = status === 'applied' || status === 'history'
  const note =
    status === 'rejected'
      ? 'proposed — NOT applied (OCC-rejected)'
      : status === 'pending'
        ? 'proposed — awaiting apply'
        : null
  return (
    <Section title={`Diff — ${diff.length} op(s)`}>
      {note && <div className="mb-1.5 text-[11px] text-gray italic">{note}</div>}
      {loading && <div className="text-xs text-gray">loading block…</div>}
      <ul className="space-y-1">
        {diff.map((op, i) => (
          <li key={i} className="flex gap-2 font-mono text-[13px]">
            <span
              className={
                'font-bold ' + (!applied ? 'text-gray' : op.op === 'assert' ? 'text-olive' : 'text-rose')
              }
            >
              {op.op === 'assert' ? '+' : '−'}
            </span>
            <span
              className={
                'break-all ' +
                (!applied
                  ? 'text-gray'
                  : op.op === 'assert'
                    ? 'text-olive'
                    : 'text-rose line-through')
              }
            >
              {op.clause}
            </span>
          </li>
        ))}
        {diff.length === 0 && !loading && (
          <li className="text-xs text-gray italic">no committed ops (read or unavailable)</li>
        )}
      </ul>
    </Section>
  )
}

function Dt({ children }: { children: React.ReactNode }) {
  return <dt className="text-[11px] leading-6 tracking-wider text-gray uppercase">{children}</dt>
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="border-t border-gray/15 px-4 py-3">
      <h3 className="mb-2 text-[11px] font-semibold tracking-wider text-gray uppercase">{title}</h3>
      {children}
    </section>
  )
}

function StatusBadge({ status }: { status: TxStatus }) {
  const cls = {
    history: 'bg-gray/15 text-teal',
    pending: 'bg-gold-soft/40 text-teal',
    applied: 'bg-olive/15 text-olive',
    rejected: 'bg-rose/15 text-rose',
  }[status]
  const label = { history: 'committed', pending: 'committing…', applied: 'applied', rejected: 'rejected' }[status]
  return <span className={`rounded-full px-2 py-0.5 text-[11px] font-medium ${cls}`}>{label}</span>
}

function Bindings({ result }: { result: NonNullable<LiveTx['result']> }) {
  const rows = Array.isArray(result) ? result : typeof result === 'string' ? null : [result]
  if (rows === null) return <pre className="font-mono text-[13px]">{String(result)}</pre>
  const solutions = rows.filter((r) => Object.keys(r).length > 0)
  if (solutions.length === 0) return <div className="text-xs text-gray italic">true (no bindings)</div>
  return (
    <div className="space-y-2">
      {solutions.map((sol, i) => (
        <div key={i} className="rounded-lg bg-cream p-2">
          {Object.entries(sol).map(([v, t]) => (
            <div key={v} className="font-mono text-[13px]">
              <span className="text-teal-light">{v}</span> <span className="text-gray">=</span>{' '}
              <span className="break-all text-teal">{t}</span>
            </div>
          ))}
        </div>
      ))}
    </div>
  )
}

function CertSection({ cert }: { cert: Cert }) {
  if (!cert) return null
  return (
    <Section
      title={
        cert.kind === 'implicit'
          ? `Quorum certificate — implicit via child #${cert.child_slot}`
          : `Quorum certificate — ${cert.kind}`
      }
    >
      <div className="flex flex-wrap gap-1.5">
        {cert.signers.map((s, i) => (
          <span
            key={i}
            title={s.pubkey ?? undefined}
            className="rounded-full border border-teal-light/30 bg-teal/5 px-2 py-0.5 font-mono text-[11px] text-teal-light"
          >
            {s.id}
          </span>
        ))}
      </div>
    </Section>
  )
}
