// The detail drawer: everything known about one transaction. Live rows carry full
// detail already; history rows lazy-load their block for diff/result/cert.

import { useQuery } from '@tanstack/react-query'
import { fetchBlock } from './api'
import type { Cert, Effect, Op, SignedRequest } from './api'
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
        {full.origin && (
          <>
            <Dt>Proof origin</Dt>
            <dd className="font-mono text-xs break-all">
              {full.origin.ns}
              <span className="ml-1 text-gray" title={full.origin.anchor}>
                ({shortHex(full.origin.anchor, 12)})
              </span>
            </dd>
          </>
        )}
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
        <Dt>Author sequence</Dt>
        <dd className="font-mono">{full.author_seq}</dd>
        <Dt>Author signature</Dt>
        <dd>
          <SignatureBadge status={full.signature_status} />
        </dd>
        {full.signature && (
          <>
            <Dt>Signature bytes</Dt>
            <dd className="font-mono text-[11px] break-all text-gray">{full.signature}</dd>
          </>
        )}
        <Dt>Tx id</Dt>
        <dd className="font-mono text-xs break-all">{full.tx_id}</dd>
        {full.proof_id && (
          <>
            <Dt>Proof id</Dt>
            <dd className="font-mono text-xs break-all text-gray">{full.proof_id}</dd>
          </>
        )}
        {full.plan_digest && (
          <>
            <Dt>Plan digest</Dt>
            <dd className="font-mono text-xs break-all text-gray">{full.plan_digest}</dd>
          </>
        )}
        <Dt>Read set</Dt>
        <dd className="text-xs text-gray">{full.read_predicates} predicate(s) checked (OCC)</dd>
      </dl>

      {full.request && <SignedRequestSection request={full.request} />}

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

      <EffectsSection effects={full.effects} loading={block.isLoading} />

      <CertSection cert={full.cert} />
    </aside>
  )
}

function SignedRequestSection({ request }: { request: SignedRequest }) {
  return (
    <Section title="Signed user request">
      <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-xs">
        <Dt>Status</Dt>
        <dd>{request.status}</dd>
        {request.user && (
          <>
            <Dt>User</Dt>
            <dd className="font-mono break-all" title={request.user.pubkey ?? undefined}>{request.user.id}</dd>
          </>
        )}
        <Dt>Request digest</Dt>
        <dd className="font-mono break-all text-gray">{request.request_digest ?? 'invalid'}</dd>
        <Dt>Operation id</Dt>
        <dd className="font-mono break-all text-gray">{request.operation_id ?? 'invalid'}</dd>
        {request.operation_ref && (
          <>
            <Dt>Operation ref</Dt>
            <dd className="font-mono break-all text-gray">
              {request.operation_ref.ns}:{request.operation_ref.operation_id}
            </dd>
          </>
        )}
        <Dt>Mode</Dt>
        <dd>{request.mode ?? 'invalid'}</dd>
        <Dt>Valid until</Dt>
        <dd>{request.not_after_ms == null ? 'invalid' : timestamp(request.not_after_ms)}</dd>
        {request.signature && (
          <>
            <Dt>User signature</Dt>
            <dd className="font-mono text-[11px] break-all text-gray">{request.signature}</dd>
          </>
        )}
        {request.first_outcome && (
          <>
            <Dt>First outcome</Dt>
            <dd className="font-mono break-all text-gray">
              {request.first_outcome.kind}:{request.first_outcome.tx_id ?? request.first_outcome.group_id}
            </dd>
          </>
        )}
      </dl>
    </Section>
  )
}

function EffectsSection({ effects, loading }: { effects: Effect[]; loading: boolean }) {
  return (
    <Section title={`Lifecycle effects — ${effects.length}`}>
      {loading && <div className="text-xs text-gray">loading block…</div>}
      <div className="space-y-3">
        {effects.map((effect) => (
          <article key={effect.effect_id} className="rounded-lg border border-teal/15 bg-cream p-3">
            <div className="flex items-center justify-between gap-3">
              <span className="font-mono text-sm font-semibold text-teal">{effect.operation}</span>
              <EffectBadge status={effect.local_execution} />
            </div>
            <dl className="mt-2 grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-xs">
              <Dt>Target</Dt>
              <dd className="font-mono break-all">
                {effect.target.ns} <span className="text-gray">({shortHex(effect.target.anchor, 12)})</span>
              </dd>
              <Dt>Actor</Dt>
              <dd className="font-mono break-all" title={effect.actor.identity.pubkey ?? undefined}>
                {effect.actor.kind}:{effect.actor.identity.id}
              </dd>
              <Dt>Authorized by</Dt>
              <dd>the transaction author node</dd>
              <Dt>Executor</Dt>
              <dd className="font-mono break-all" title={effect.executor.pubkey ?? undefined}>
                {effect.executor.id}
              </dd>
              <Dt>Effect id</Dt>
              <dd className="font-mono break-all text-gray">{effect.effect_id}</dd>
              <Dt>Request digest</Dt>
              <dd className="font-mono break-all text-gray">{effect.request_digest}</dd>
              <Dt>Prepared digest</Dt>
              <dd className="font-mono break-all text-gray">{effect.prepared_digest}</dd>
              {effect.local_execution_height != null && effect.local_execution_height > 0 && (
                <>
                  <Dt>Executed at</Dt>
                  <dd className="font-mono">root height #{effect.local_execution_height}</dd>
                </>
              )}
              {effect.local_execution_result != null && (
                <>
                  <Dt>Local result</Dt>
                  <dd className="font-mono break-all">{effect.local_execution_result}</dd>
                </>
              )}
            </dl>
          </article>
        ))}
        {effects.length === 0 && !loading && (
          <div className="text-xs text-gray italic">no lifecycle effects</div>
        )}
      </div>
    </Section>
  )
}

function EffectBadge({ status }: { status: Effect['local_execution'] }) {
  const style = {
    pending: ['pending', 'bg-gold-soft/40 text-teal'],
    applied: ['executed here', 'bg-olive/15 text-olive'],
    retired: ['retired', 'bg-gray/15 text-gray'],
    operator_error: ['operator error', 'bg-rose/15 text-rose'],
    unavailable: ['local status unavailable', 'bg-gray/15 text-gray'],
    not_this_node: ['executed on another node', 'bg-teal/10 text-teal-light'],
  }[status]
  return <span className={`rounded-full px-2 py-0.5 text-[11px] font-medium ${style[1]}`}>{style[0]}</span>
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

function SignatureBadge({ status }: { status: LiveTx['signature_status'] }) {
  const cls = {
    verified: 'bg-olive/15 text-olive',
    genesis: 'bg-teal-light/15 text-teal-light',
    unsigned: 'bg-gold-soft/40 text-teal',
    invalid: 'bg-rose/15 text-rose',
    unknown: 'bg-gray/15 text-gray',
  }[status]
  const label = {
    verified: 'verified',
    genesis: 'trusted genesis',
    unsigned: 'unsigned',
    invalid: 'invalid',
    unknown: 'loading…',
  }[status]
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
