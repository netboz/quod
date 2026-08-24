// The prove console keeps the exact proof alive between solutions. Writes remain
// staged until the displayed solution is explicitly accepted.

import { useEffect, useRef, useState } from 'react'
import {
  acceptProofSolution,
  nextProofSolution,
  openProofCursor,
  stopProofCursor,
} from './api'
import type { ProveReply } from './api'
import { useSignedSession } from './session-context'
import { shortNamespace } from './namespace'

const EXAMPLES = ['isa(X, Y)', 'assertz(capital(france, paris))', 'capital(france, X)']

export function Console({ ns, anchor }: { ns: string; anchor: string }) {
  const { identity, agent, error: sessionError } = useSignedSession()
  const [goal, setGoal] = useState('')
  const [busy, setBusy] = useState(false)
  const [reply, setReply] = useState<ProveReply | null>(null)
  const [cursor, setCursor] = useState<string | null>(null)
  const [solutionNumber, setSolutionNumber] = useState(0)
  const cursorRef = useRef<string | null>(null)
  const identityRef = useRef(identity)
  identityRef.current = identity
  const nsRef = useRef(ns)
  nsRef.current = ns

  const rememberCursor = (next: string | null) => {
    cursorRef.current = next
    setCursor(next)
  }

  useEffect(() => {
    const openCursor = cursorRef.current
    if (openCursor) {
      cursorRef.current = null
      setCursor(null)
      setReply(null)
      setSolutionNumber(0)
      if (identityRef.current) void stopProofCursor(identityRef.current, openCursor)
    }
  }, [ns])

  useEffect(() => {
    return () => {
      const openCursor = cursorRef.current
      if (openCursor && identityRef.current) {
        void stopProofCursor(identityRef.current, openCursor)
      }
    }
  }, [])

  const applyReply = (next: ProveReply, isNext = false) => {
    if ('error' in next && (next.error === 'cursor_busy' || next.error === 'cursor_not_ready')) {
      // These replies describe a live cursor whose current command has not
      // become terminal. Keep both its capability and displayed solution so
      // the user can retry without losing the exact proof position.
      return
    }
    setReply(next)
    if ('result' in next && next.result === 'solution') {
      rememberCursor(next.cursor)
      setSolutionNumber((n) => (isNext ? n + 1 : 1))
    } else {
      rememberCursor(null)
      setSolutionNumber(0)
    }
  }

  const run = async () => {
    if (!identity || !agent || !goal.trim() || busy || cursor) return
    setBusy(true)
    setReply(null)
    const requestNs = ns
    try {
      const next = await openProofCursor(identity, agent, requestNs, anchor, goal)
      if (nsRef.current !== requestNs) {
        if ('result' in next && next.result === 'solution') {
          void stopProofCursor(identity, next.cursor)
        }
        return
      }
      applyReply(next)
    } catch (e) {
      setReply({ error: String(e) })
    } finally {
      setBusy(false)
    }
  }

  const command = async (kind: 'next' | 'accept' | 'stop') => {
    if (!identity || !cursor || busy) return
    setBusy(true)
    const requestNs = ns
    try {
      const next =
        kind === 'next'
          ? await nextProofSolution(identity, cursor)
          : kind === 'accept'
            ? await acceptProofSolution(identity, cursor)
            : await stopProofCursor(identity, cursor)
      if (nsRef.current !== requestNs) return
      applyReply(next, kind === 'next')
    } catch (e) {
      setReply({ error: String(e) })
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="rounded-xl border border-teal/35 bg-white/90 shadow-sm">
      <header className="flex items-center justify-between border-b border-teal-dark/30 bg-teal px-4 py-2.5 text-cream">
        <h2 className="min-w-0 text-[11px] font-semibold tracking-wider text-cream/80 uppercase">
          Prove console —{' '}
          <span className="font-mono normal-case" title={ns}>
            {shortNamespace(ns)}
          </span>
        </h2>
        <span className="text-[11px] text-cream/70">reads answer · writes commit</span>
      </header>
      <div className="p-4">
        {identity && agent ? (
          <>
            <div className="flex items-start gap-2">
              <span className="pt-2 font-mono text-sm text-gray select-none">?-</span>
              <textarea
                value={goal}
                onChange={(e) => setGoal(e.target.value)}
                disabled={cursor !== null}
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
                disabled={busy || !goal.trim() || cursor !== null}
                className="rounded-lg bg-gold px-5 py-2 text-sm font-semibold text-teal shadow-sm transition hover:bg-gold-soft disabled:opacity-40"
              >
                {busy ? 'Proving…' : 'Run'}
              </button>
            </div>
            <div className="mt-2 flex gap-2 text-[11px] text-gray">
              {EXAMPLES.map((e) => (
                <button key={e} disabled={cursor !== null} onClick={() => setGoal(e)} className="rounded bg-gold-soft/35 px-2 py-0.5 font-mono text-teal-light hover:bg-gold-soft/60 hover:text-teal disabled:opacity-40">
                  {e}
                </button>
              ))}
            </div>
          </>
        ) : (
          <div className="rounded-lg border border-gold/45 bg-gold-soft/15 px-3 py-2 text-sm text-teal">
            {identity
              ? 'Add or select an agent above before running a goal.'
              : 'Create a signing key above, then add an agent reference.'}
            {' '}The console signs the exact Prolog text; every ontology's normal ACL still
            decides whether it is allowed.
            {sessionError && <span className="ml-2 text-rose">{sessionError}</span>}
          </div>
        )}
        {reply && <Reply reply={reply} solutionNumber={solutionNumber} />}
        {cursor && (
          <div className="mt-3 flex flex-wrap items-center gap-2 border-t border-teal/15 pt-3">
            <button
              onClick={() => void command('next')}
              disabled={busy}
              className="rounded-lg bg-teal px-4 py-2 text-sm font-semibold text-cream hover:bg-teal-light disabled:opacity-40"
            >
              {busy ? 'Working…' : 'Next solution'}
            </button>
            <button
              onClick={() => void command('accept')}
              disabled={busy}
              className="rounded-lg bg-gold px-4 py-2 text-sm font-semibold text-teal hover:bg-gold-soft disabled:opacity-40"
            >
              Accept solution
            </button>
            <button
              onClick={() => void command('stop')}
              disabled={busy}
              className="rounded-lg border border-rose/35 px-4 py-2 text-sm font-semibold text-rose hover:bg-rose/5 disabled:opacity-40"
            >
              Stop
            </button>
            <span className="text-xs text-gray">
              Writes remain staged until you accept; ordinary writes survive Next unless wrapped in transaction/1.
            </span>
          </div>
        )}
      </div>
    </div>
  )
}

function Reply({ reply, solutionNumber }: { reply: ProveReply; solutionNumber: number }) {
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
    return (
      <div className="mt-3 rounded-lg border border-rose/30 bg-rose/5 px-3 py-2 text-sm text-rose">
        <div className="font-mono">false.</div>
        {reply.reasons && reply.reasons.length > 0 && (
          <div className="mt-2 border-t border-rose/20 pt-2">
            <div className="text-[11px] font-semibold tracking-wider uppercase">Failure reasons</div>
            <ol className="mt-1 space-y-1 font-mono text-[13px] text-teal">
              {reply.reasons.map((reason, i) => (
                <li key={`${i}:${reason}`} className="break-all">
                  {reason}
                </li>
              ))}
            </ol>
          </div>
        )}
      </div>
    )
  }
  if (reply.result === 'pending') {
    const isGroup = 'group_id' in reply
    return (
      <div className="mt-3 rounded-lg border border-gold/50 bg-gold-soft/20 px-3 py-2 text-sm text-teal">
        <div className="font-semibold">Outcome still pending</div>
        <div className="mt-1 text-xs text-gray">
          Do not resubmit this operation. {isGroup ? 'Group' : 'Transaction'} in{' '}
          <span className="font-mono text-teal">{reply.ns}</span>, anchor{' '}
          <span className="font-mono text-teal">{reply.anchor.slice(0, 12)}…</span>, identifier{' '}
          <span className="font-mono text-teal">
            {isGroup ? reply.group_id : reply.tx_id}
          </span>{' '}
          may still be committed; its anchored status can be queried safely.
        </div>
      </div>
    )
  }
  if (reply.result === 'stopped') {
    return (
      <div className="mt-3 rounded-lg border border-gray/25 bg-gray/5 px-3 py-2 text-sm text-gray">
        Proof stopped. No staged writes were committed.
      </div>
    )
  }
  if (reply.result === 'solution') {
    return (
      <div className="mt-3 rounded-lg border border-gold/55 bg-gold-soft/15 px-3 py-2 text-sm">
        <div className="font-medium text-teal">
          Solution {solutionNumber}<span className="text-gray"> · provisional · height #{reply.height}</span>
        </div>
        {reply.bindings.filter((b) => Object.keys(b).length > 0).map((b, i) => (
          <div key={i} className="mt-1 font-mono text-[13px] text-teal">
            {Object.entries(b).map(([v, t]) => `${v} = ${t}`).join(', ')}
          </div>
        ))}
      </div>
    )
  }
  if ('group_id' in reply) {
    return (
      <div className="mt-3 rounded-lg border border-olive/30 bg-olive/5 px-3 py-2 text-sm">
        <div className="font-medium text-olive">true · group committed at origin height #{reply.height}</div>
        <div className="mt-1 text-xs text-gray">
          group <span className="font-mono text-teal">{reply.group_id}</span> · {reply.participant_slots.length} ontologies
        </div>
        {reply.bindings.filter((b) => Object.keys(b).length > 0).map((b, i) => (
          <div key={i} className="mt-1 font-mono text-[13px] text-teal">
            {Object.entries(b).map(([v, t]) => `${v} = ${t}`).join(', ')}
          </div>
        ))}
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
