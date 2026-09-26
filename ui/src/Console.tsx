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
import type { ProofView } from '../../client/src/world.js'
import type { WorldScene } from '../../client/src/world-scene.js'

const EXAMPLES = ['isa(X, Y)', 'assertz(capital(france, paris))', 'capital(france, X)']

const DEFAULT_VIEW: ProofView = {
  title: 'Prove console', goal: 'Prolog goal', results: 'Bindings',
  run: 'Run', next: 'Next solution', accept: 'Accept solution', stop: 'Stop',
}

type ConsoleProps = { ns: string; anchor: string; view?: ProofView;
  surface?: { scene: WorldScene | null; visible: boolean; close: () => void } }

export function Console(props: ConsoleProps) {
  const { identity, agent } = useSignedSession()
  // A cursor belongs to its signing session, actor and exact target. Changing
  // any of them retires the old component, even within the same namespace.
  const scope = JSON.stringify([identity?.session.session_id, agent?.id, props.ns, props.anchor])
  return <ScopedConsole key={scope} {...props} />
}

function ScopedConsole({ ns, anchor, view = DEFAULT_VIEW, surface }: ConsoleProps) {
  const { identity, agent, error: sessionError } = useSignedSession()
  const [goal, setGoal] = useState('')
  const [busy, setBusy] = useState(false)
  const [reply, setReply] = useState<ProveReply | null>(null)
  const [cursor, setCursor] = useState<string | null>(null)
  const [solutionNumber, setSolutionNumber] = useState(0)
  const cursorRef = useRef<string | null>(null)
  const active = useRef(true)
  // Both renderers can dispatch before React paints the disabled controls.
  const working = useRef(false)
  const setWorking = (value: boolean) => { working.current = value; setBusy(value) }
  const edit = (value: string) => {
    if (active.current && !working.current && !cursorRef.current) setGoal(value)
  }

  const rememberCursor = (next: string | null) => {
    cursorRef.current = next
    setCursor(next)
  }

  useEffect(() => {
    active.current = true
    return () => {
      active.current = false
      const openCursor = cursorRef.current
      if (openCursor && identity) void stopProofCursor(identity, openCursor)
    }
  }, [identity])

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
    if (!active.current || !identity || !agent || !goal.trim() || working.current || cursorRef.current) return
    setWorking(true)
    setReply(null)
    try {
      const next = await openProofCursor(identity, agent, ns, anchor, goal)
      if (!active.current) {
        if ('result' in next && next.result === 'solution') {
          void stopProofCursor(identity, next.cursor)
        }
        return
      }
      applyReply(next)
    } catch (e) {
      if (active.current) setReply({ error: String(e) })
    } finally {
      if (active.current) setWorking(false)
    }
  }

  const command = async (kind: 'next' | 'accept' | 'stop') => {
    if (!active.current || !identity || !cursor || working.current) return
    setWorking(true)
    try {
      const next =
        kind === 'next'
          ? await nextProofSolution(identity, cursor)
          : kind === 'accept'
            ? await acceptProofSolution(identity, cursor)
            : await stopProofCursor(identity, cursor)
      if (!active.current) return
      applyReply(next, kind === 'next')
    } catch (e) {
      if (active.current) setReply({ error: String(e) })
    } finally {
      if (active.current) setWorking(false)
    }
  }

  const result = replyText(reply, solutionNumber)
  const scene = surface?.scene
  useEffect(() => () => { scene?.setWorkspace(null) }, [scene])
  // Only the view changes on XR entry/exit; this component remains the
  // single owner of the draft, cursor, and signed commands.
  useEffect(() => {
    scene?.setWorkspace(surface?.visible ? {
      view, scope: ns, goal, result, locked: busy || cursor !== null,
      enabled: { run: !busy && !cursor && !!goal.trim(),
        next: !busy && !!cursor, accept: !busy && !!cursor, stop: !busy && !!cursor },
      edit, run: () => { void run() }, next: () => { void command('next') },
      accept: () => { void command('accept') }, stop: () => { void command('stop') },
      close: surface.close,
    } : null)
  })

  return (
    <div className="rounded-xl border border-teal/35 bg-white/90 shadow-sm">
      <header className="flex items-center justify-between border-b border-teal-dark/30 bg-teal px-4 py-2.5 text-cream">
        <h2 className="min-w-0 text-[11px] font-semibold tracking-wider text-cream/80 uppercase">
          {view.title} —{' '}
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
                aria-label={view.goal}
                onChange={(e) => edit(e.target.value)}
                disabled={busy || cursor !== null}
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
                {busy ? 'Proving…' : view.run}
              </button>
            </div>
            <div className="mt-2 flex gap-2 text-[11px] text-gray">
              {EXAMPLES.map((e) => (
                <button key={e} disabled={busy || cursor !== null} onClick={() => edit(e)} className="rounded bg-gold-soft/35 px-2 py-0.5 font-mono text-teal-light hover:bg-gold-soft/60 hover:text-teal disabled:opacity-40">
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
        {reply && <pre aria-label={view.results} className="mt-3 whitespace-pre-wrap break-words rounded-lg border border-teal/20 bg-cream p-3 text-sm text-teal">{result}</pre>}
        {cursor && (
          <div className="mt-3 flex flex-wrap items-center gap-2 border-t border-teal/15 pt-3">
            <button
              onClick={() => void command('next')}
              disabled={busy}
              className="rounded-lg bg-teal px-4 py-2 text-sm font-semibold text-cream hover:bg-teal-light disabled:opacity-40"
            >
              {busy ? 'Working…' : view.next}
            </button>
            <button
              onClick={() => void command('accept')}
              disabled={busy}
              className="rounded-lg bg-gold px-4 py-2 text-sm font-semibold text-teal hover:bg-gold-soft disabled:opacity-40"
            >
              {view.accept}
            </button>
            <button
              onClick={() => void command('stop')}
              disabled={busy}
              className="rounded-lg border border-rose/35 px-4 py-2 text-sm font-semibold text-rose hover:bg-rose/5 disabled:opacity-40"
            >
              {view.stop}
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

// Both the desktop and spatial binding views display the same complete reply.
function replyText(reply: ProveReply | null, solutionNumber: number): string {
  if (!reply) return ''
  if ('error' in reply) return [reply.error, reply.detail].filter(Boolean).join(' — ')
  if (reply.result === 'fail') return ['false.', ...(reply.reasons ?? [])].join('\n')
  if (reply.result === 'stopped') return 'Proof stopped. No staged writes were committed.'
  if (reply.result === 'pending') return [
    'Outcome still pending. Do not resubmit this operation.',
    `Ontology: ${reply.ns}`, `Anchor: ${reply.anchor}`,
    'group_id' in reply ? `Group: ${reply.group_id}` : `Transaction: ${reply.tx_id}`,
  ].join('\n')
  const lines = [reply.result === 'solution'
    ? `Solution ${solutionNumber} — provisional — height #${reply.height}`
    : 'height' in reply ? `true — height #${reply.height}` : `true — committed in ${reply.ns}`]
  if ('ns' in reply) lines.push(`Ontology: ${reply.ns}`, `Anchor: ${reply.anchor}`)
  if ('group_id' in reply) lines.push(`Group: ${reply.group_id} — ${reply.participant_slots.length} ontologies`)
  if ('tx_id' in reply) lines.push(`Transaction: ${reply.tx_id}`)
  for (const bindings of reply.bindings) {
    for (const [name, term] of Object.entries(bindings)) lines.push(`${name} = ${term}`)
  }
  return lines.join('\n')
}

// Kept mounted while the world hides its focused panel: drafts and cursors
// survive returning to the room. The signed origin binds the exact agent.
export function ConsoleWorkspace({ view, onClose, scene, visible }: { view: ProofView; onClose: () => void; scene: WorldScene | null; visible: boolean }) {
  const { identity, agent } = useSignedSession()
  return <main className="mx-auto flex min-h-screen max-w-7xl flex-col gap-6 p-8">
    <header className="flex items-center justify-between gap-4">
      <div><p className="text-xs tracking-widest uppercase">Quod · personal workspace</p>
        <h1 className="text-2xl font-semibold">{view.title}</h1></div>
      <button className="rounded-lg border px-4 py-2" onClick={onClose}>Return to lobby</button>
    </header>
    {identity && agent && <Console
      ns={agent.namespace} anchor={String(agent.anchor)} view={view}
      surface={{ scene, visible, close: onClose }} />}
    <p className="text-sm">The goal runs in your selected agent's ontology. Use an explicit
      ontology selection in the goal to work in another scope. Returning to the lobby preserves
      your draft; accepting a solution is the step that commits staged changes.</p>
  </main>
}
