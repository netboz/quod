// The prove console: run any goal against the selected ontology through the normal
// path — a read answers with bindings, a write commits and lands in the live list.

import { useState } from 'react'
import { prove } from './api'
import type { ProveReply } from './api'

const EXAMPLES = ['isa(X, Y)', 'assertz(capital(france, paris))', 'capital(france, X)']

export function Console({ ns }: { ns: string }) {
  const [goal, setGoal] = useState('')
  const [busy, setBusy] = useState(false)
  const [reply, setReply] = useState<ProveReply | null>(null)

  const run = async () => {
    if (!goal.trim() || busy) return
    setBusy(true)
    setReply(null)
    try {
      setReply(await prove(ns, goal))
    } catch (e) {
      setReply({ error: String(e) })
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="rounded-xl border border-teal/35 bg-white/90 shadow-sm">
      <header className="flex items-center justify-between border-b border-teal-dark/30 bg-teal px-4 py-2.5 text-cream">
        <h2 className="text-[11px] font-semibold tracking-wider text-cream/80 uppercase">
          Prove console — <span className="font-mono normal-case">{ns}</span>
        </h2>
        <span className="text-[11px] text-cream/70">reads answer · writes commit</span>
      </header>
      <div className="p-4">
        <div className="flex items-start gap-2">
          <span className="pt-2 font-mono text-sm text-gray select-none">?-</span>
          <textarea
            value={goal}
            onChange={(e) => setGoal(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault()
                void run()
              }
            }}
            rows={2}
            spellCheck={false}
            placeholder="assertz(capital(france, paris))"
            className="min-h-9 flex-1 resize-y rounded-lg border border-teal-light/45 bg-cream px-3 py-2 font-mono text-sm text-teal focus:border-teal-light focus:ring-2 focus:ring-gold/55 focus:outline-none"
          />
          <button
            onClick={() => void run()}
            disabled={busy || !goal.trim()}
            className="rounded-lg bg-gold px-5 py-2 text-sm font-semibold text-teal shadow-sm transition hover:bg-gold-soft disabled:opacity-40"
          >
            {busy ? 'Proving…' : 'Run'}
          </button>
        </div>
        <div className="mt-2 flex gap-2 text-[11px] text-gray">
          {EXAMPLES.map((e) => (
            <button key={e} onClick={() => setGoal(e)} className="rounded bg-gold-soft/35 px-2 py-0.5 font-mono text-teal-light hover:bg-gold-soft/60 hover:text-teal">
              {e}
            </button>
          ))}
        </div>
        {reply && <Reply reply={reply} />}
      </div>
    </div>
  )
}

function Reply({ reply }: { reply: ProveReply }) {
  if ('error' in reply) {
    return (
      <div className="mt-3 rounded-lg border border-rose/30 bg-rose/5 px-3 py-2 text-sm text-rose">
        <span className="font-semibold">{reply.error}</span>
        {reply.detail && <span className="ml-2 font-mono text-xs">{reply.detail}</span>}
        {reply.error === 'not_leader' && (
          <span className="ml-2 text-xs">
            this node doesn't lead the current slot{reply.leader ? ` — leader is ${reply.leader.id}` : ''}; retry or
            submit there
          </span>
        )}
      </div>
    )
  }
  if (reply.result === 'fail') {
    return <div className="mt-3 rounded-lg bg-cream px-3 py-2 font-mono text-sm text-gray">false.</div>
  }
  if (reply.result === 'pending') {
    return (
      <div className="mt-3 rounded-lg border border-gold/50 bg-gold-soft/20 px-3 py-2 text-sm text-teal">
        <div className="font-semibold">Outcome still pending</div>
        <div className="mt-1 text-xs text-gray">
          Do not resubmit this operation. Target <span className="font-mono text-teal">{reply.ns}</span>,
          anchor <span className="font-mono text-teal">{reply.anchor.slice(0, 12)}…</span>, transaction{' '}
          <span className="font-mono text-teal">{reply.tx_id}</span> may still be committed;
          its target-anchored status can be queried safely.
        </div>
      </div>
    )
  }
  if (!('height' in reply)) {
    return (
      <div className="mt-3 rounded-lg border border-olive/30 bg-olive/5 px-3 py-2 text-sm">
        <div className="font-medium text-olive">true · committed in {reply.ns}</div>
        <div className="mt-1 text-xs text-gray">
          anchor <span className="font-mono text-teal">{reply.anchor.slice(0, 12)}…</span>, transaction{' '}
          <span className="font-mono text-teal">{reply.tx_id}</span>
        </div>
        {reply.bindings.filter((b) => Object.keys(b).length > 0).map((b, i) => (
          <div key={i} className="mt-1 font-mono text-[13px] text-teal">
            {Object.entries(b).map(([v, t]) => `${v} = ${t}`).join(', ')}
          </div>
        ))}
      </div>
    )
  }
  return (
    <div className="mt-3 rounded-lg border border-olive/30 bg-olive/5 px-3 py-2 text-sm">
      <div className="font-medium text-olive">
        true<span className="text-gray"> · height #{reply.height}</span>
      </div>
      {reply.bindings.filter((b) => Object.keys(b).length > 0).map((b, i) => (
        <div key={i} className="mt-1 font-mono text-[13px] text-teal">
          {Object.entries(b)
            .map(([v, t]) => `${v} = ${t}`)
            .join(', ')}
        </div>
      ))}
    </div>
  )
}
