import { useEffect, useRef, useState } from 'react'
import { useSignedSession } from './session-context'
import { useProofCursor, replyText } from './Console'
import { codeForm } from '../../client/src/world.js'
import type { WorldScene } from '../../client/src/world-scene.js'
import type { EidolonWorkspace } from '../../client/src/world.js'
import { formatTerm } from '../../client/src/prolog-term.js'
import type { PrologTerm } from '../../client/src/prolog-term.js'
import { readCodePredicates, readCodeSource, prepareCodeEdit, predicateIndicator, readCodeClauses, clausesSource } from '../../client/src/prolog-edit.js'

import type { ClauseCard } from '../../client/src/prolog-edit.js'

type Draft = { baseline: string; source: string; cards?: ClauseCard[] }

// Catalogue reads and local drafts meet in one choice list. A late initial
// read must not erase a predicate restored from an unresolved signed edit.
function mergePredicates(...catalogues: PrologTerm[][]) {
  const choices = new Map<string, PrologTerm>()
  for (const predicate of catalogues.flat()) choices.set(formatTerm(predicate), predicate)
  return [...choices.values()]
}

type EditorProps = { workspace: EidolonWorkspace; onClose: () => void; scene: WorldScene | null; visible: boolean }

export function PrologEditor(props: EditorProps) {
  const { identity, agent } = useSignedSession()
  const scope = JSON.stringify([identity?.session.session_id, agent?.id, props.workspace.target, props.workspace.tools])
  return <ScopedEditor key={scope} {...props} />
}

function ScopedEditor({ workspace, onClose, scene, visible }: EditorProps) {
  const { identity, agent } = useSignedSession()
  const view = codeForm(workspace.view)
  const proof = useProofCursor(agent?.namespace ?? '', String(agent?.anchor ?? ''), JSON.stringify(['prolog', workspace.target]))
  const [predicates, setPredicates] = useState<PrologTerm[]>([])
  const [selected, setSelected] = useState('')
  const [newPredicate, setNewPredicate] = useState('')
  const [layout, setLayout] = useState<'text' | 'cards'>('text')
  const [cardIndex, setCardIndex] = useState(0)
  const [drafts, setDrafts] = useState<Record<string, Draft>>({})
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [goal, setGoal] = useState('')
  const live = useRef(true)
  const pending = useRef(false)
  const submitted = useRef<{ indicator: string; source: string } | null>(null)
  const indicator = predicates.find(predicate => formatTerm(predicate) === selected)
  const draft = drafts[selected]
  const locked = loading || proof.busy || proof.cursor !== null || proof.pendingOperation !== null

  useEffect(() => {
    live.current = true
    if (identity && agent) {
      setLoading(true)
      void readCodePredicates(identity, agent, workspace).then(items => {
        if (live.current) { setPredicates(previous => mergePredicates(items, previous)); setSelected(previous => previous || (items.length ? formatTerm(items[0]) : '')) }
      }).catch(reason => { if (live.current) setError(String(reason)) })
        .finally(() => { if (live.current) setLoading(false) })
    }
    return () => { live.current = false }
  }, [identity, agent, workspace])

  useEffect(() => {
    let current = true
    if (identity && agent && indicator && !draft) {
      setLoading(true)
      void readCodeSource(identity, agent, workspace, indicator).then(source => {
        if (current) setDrafts(previous => ({ ...previous, [selected]: { source, baseline: source } }))
      }).catch(reason => { if (current) setError(String(reason)) })
        .finally(() => { if (current) setLoading(false) })
    }
    return () => { current = false }
  }, [identity, agent, workspace, indicator, selected, draft])

  useEffect(() => {
    const saved = proof.recoveryContext
    if (saved && typeof saved.indicator === 'string' && typeof saved.source === 'string' && typeof saved.baseline === 'string') {
      const indicator = saved.indicator
      const source = saved.source
      const baseline = saved.baseline
      setSelected(indicator)
      setPredicates(previous => mergePredicates(previous, [predicateIndicator(indicator)]))
      setDrafts(previous => ({ ...previous, [indicator]: { source, baseline } }))
      submitted.current = { indicator, source }
    }
  }, [proof.recoveryContext])

  useEffect(() => {
    // Only a positive terminal result advances the opened baseline. Pending
    // or unknown Accept outcomes keep the original draft and its evidence.
    const saved = submitted.current
    if (saved && proof.reply && 'result' in proof.reply && (proof.reply.result === 'ok' || (proof.reply.result === 'recovered' && proof.reply.status === 'committed'))) {
      setDrafts(previous => ({ ...previous, [saved.indicator]: { ...previous[saved.indicator], baseline: saved.source, source: saved.source } }))
      submitted.current = null
    }
  }, [proof.reply])

  const preview = async () => {
    if (!identity || !agent || !indicator || !draft || pending.current || !proof.canEdit()) return
    pending.current = true
    setLoading(true)
    setError(null)
    try {
      const edit = await prepareCodeEdit(identity, agent, workspace, indicator, draft.baseline, draft.source)
      if (!live.current) return
      setGoal(edit)
      submitted.current = { indicator: selected, source: draft.source }
      await proof.run(edit, { indicator: selected, baseline: draft.baseline, source: draft.source })
    } catch (reason) { if (live.current) setError(String(reason)) }
    finally { pending.current = false; if (live.current) setLoading(false) }
  }

  const changeLayout = async (next: string) => {
    if (locked || !proof.canEdit() || pending.current || !draft) return
    if (next === 'text') { setLayout('text'); return }
    if (next !== 'cards') return
    pending.current = true
    setLoading(true)
    try {
      const cards = await readCodeClauses(identity!, agent!, workspace, draft.source)
      if (!live.current) return
      setDrafts(previous => ({ ...previous, [selected]: { ...draft, cards } }))
      setCardIndex(0)
      setLayout('cards')
      setError(null)
    } catch (reason) { if (live.current) setError(String(reason)) }
    finally { pending.current = false; if (live.current) setLoading(false) }
  }
  const changeCards = (action: string, value = '') => {
    if (locked || !proof.canEdit() || pending.current || !draft?.cards) return
    setDrafts(previous => {
      const current = previous[selected]
      if (!current?.cards) return previous
      const cards = current.cards.map(card => ({ ...card }))
      if (action === 'add_clause') cards.push({ head: 'new_clause', body: '' })
      else if (action === 'remove_clause') cards.splice(cardIndex, 1)
      else if (action === 'move_up' && cardIndex > 0) [cards[cardIndex - 1], cards[cardIndex]] = [cards[cardIndex], cards[cardIndex - 1]]
      else if (action === 'move_down' && cardIndex + 1 < cards.length) [cards[cardIndex + 1], cards[cardIndex]] = [cards[cardIndex], cards[cardIndex + 1]]
      else if (cards[cardIndex] && (action === 'head' || action === 'body')) cards[cardIndex][action] = value
      return { ...previous, [selected]: { ...current, cards, source: clausesSource(cards) } }
    })
    if (action === 'add_clause') setCardIndex(draft.cards.length)
    if (action === 'remove_clause') setCardIndex(Math.max(0, Math.min(cardIndex, draft.cards.length - 2)))
    if (action === 'move_up') setCardIndex(Math.max(0, cardIndex - 1))
    if (action === 'move_down') setCardIndex(Math.min(draft.cards.length - 1, cardIndex + 1))
  }
  const createPredicate = () => {
    if (locked || !proof.canEdit()) return
    try {
      const indicator = predicateIndicator(newPredicate)
      const name = formatTerm(indicator)
      setPredicates(previous => mergePredicates(previous, [indicator]))
      setSelected(name)
      setLayout('text')
      setCardIndex(0)
      setNewPredicate('')
      setError(null)
      // Read the actual current baseline even for a newly typed name; another
      // author may already have created it since the predicate list was read.
    } catch (reason) { setError(String(reason)) }
  }
  const edit = (role: string, value: string) => {
    if (pending.current || !proof.canEdit() || loading) return
    if (role === 'predicate') { setSelected(value); setLayout('text'); setCardIndex(0) }
    if (role === 'layout') void changeLayout(value)
    if (role === 'clause') setCardIndex(Number(value))
    if (role === 'head' || role === 'body') changeCards(role, value)
    if (role === 'new_predicate') setNewPredicate(value)
    if (role === 'source' && draft) setDrafts(previous => ({ ...previous, [selected]: { baseline: draft.baseline, source: value } }))
  }
  const cards = draft?.cards ?? []
  const card = cards[cardIndex]
  const result = [error, replyText(proof.reply, proof.solutionNumber)].filter(Boolean).join('\n')
  useEffect(() => () => { scene?.setWorkspace(null) }, [scene])
  useEffect(() => {
    scene?.setWorkspace(visible ? {
      view: { title: workspace.view.title, fields: workspace.view.fields.flatMap(field => field.role !== 'source' ? [field] : [
        { kind: 'choice', role: 'layout', label: 'Code layout' },
        ...(layout === 'text' ? [field] : [
          { kind: 'choice', role: 'clause', label: 'Clause order' },
          { kind: 'input', role: 'head', label: 'Head' },
          { kind: 'editor', role: 'body', label: 'Body (empty for a fact)' },
          ...[['add_clause', 'Add clause'], ['remove_clause', 'Remove clause'], ['move_up', 'Move up'], ['move_down', 'Move down']]
            .map(([role, label]) => ({ kind: 'button', role, label })),
        ]),
      ]) }, scope: workspace.target.namespace,
      values: { predicate: selected, new_predicate: newPredicate, source: draft?.source ?? '', results: result,
        layout, clause: String(cardIndex), head: card?.head ?? '', body: card?.body ?? '' },
      choices: { layout: [{ value: 'text', label: 'Text' }, { value: 'cards', label: 'Clause cards' }],
        clause: cards.map((card, index) => ({ value: String(index), label: `${index + 1}. ${card.head}` })), predicate: predicates.map(predicate => { const value = formatTerm(predicate); return { value, label: value } }) },
      locked,
      enabled: { run: !locked && !!draft, accept: !proof.busy && !!proof.cursor, stop: !proof.busy && !!proof.cursor,
        create: !locked && !!newPredicate.trim(), resolve: !proof.busy && !!proof.pendingOperation,
        add_clause: !locked, remove_clause: !locked && !!card, move_up: !locked && cardIndex > 0, move_down: !locked && cardIndex + 1 < cards.length },
      edit,
      invoke: role => { if (role === 'run') void preview(); else if (role === 'create') createPredicate(); else if (role === 'resolve') void proof.resolve(); else if (role === 'accept' || role === 'stop') void proof.command(role);
        else if (['add_clause', 'remove_clause', 'move_up', 'move_down'].includes(role)) changeCards(role) },
      close: onClose,
    } : null)
  })

  return <main className="mx-auto flex min-h-screen max-w-7xl flex-col gap-5 p-8">
    <header className="flex items-start justify-between gap-4">
      <div><h1 className="text-2xl font-semibold">{view.title}</h1>
        <p className="font-mono text-sm">{workspace.target.namespace}</p></div>
      <button className="rounded-lg border px-4 py-2" onClick={onClose}>Return to lobby</button>
    </header>
    <p>These are the ontology's stored rules. Shared base rules are included; changing them here changes this ontology only.</p>
    <label>{view.predicate} <select value={selected} disabled={locked} onChange={event => edit('predicate', event.target.value)}>
      {predicates.map(predicate => { const name = formatTerm(predicate); return <option key={name} value={name}>{name}</option> })}
    </select></label>
    <label>{view.new_predicate} <input aria-label={view.new_predicate} value={newPredicate} disabled={locked}
      onChange={event => edit('new_predicate', event.target.value)} />
      <button disabled={locked || !newPredicate.trim()} onClick={createPredicate}>{view.create}</button></label>
    <label>Code layout <select aria-label="Code layout" value={layout} disabled={locked || !draft}
      onChange={event => void changeLayout(event.target.value)}><option value="text">Text</option><option value="cards">Clause cards</option></select></label>
    {layout === 'text' ? <label className="flex flex-1 flex-col gap-2">{view.source}
      <textarea aria-label={view.source} value={draft?.source ?? ''} rows={18} spellCheck={false}
        className="min-h-80 w-full rounded-lg border bg-white p-4 font-mono text-sm"
        disabled={locked || !draft} onChange={event => edit('source', event.target.value)} />
    </label> : <section aria-label="Clause cards" className="flex flex-col gap-3 rounded-xl border p-4">
      <label>Clause order <select aria-label="Clause order" value={cardIndex} disabled={locked || !cards.length}
        onChange={event => setCardIndex(Number(event.target.value))}>
        {cards.map((card, index) => <option key={index} value={index}>{index + 1}. {card.head}</option>)}
      </select></label>
      <label>Head<input aria-label="Clause head" value={card?.head ?? ''} disabled={locked || !card}
        onChange={event => changeCards('head', event.target.value)} className="w-full rounded border p-3 font-mono" /></label>
      <label>Body (empty for a fact)<textarea aria-label="Clause body" value={card?.body ?? ''} disabled={locked || !card}
        onChange={event => changeCards('body', event.target.value)} rows={8} className="w-full rounded border p-3 font-mono" /></label>
      <div className="flex gap-4">
        <button disabled={locked} onClick={() => changeCards('add_clause')}>Add clause</button>
        <button disabled={locked || !card} onClick={() => changeCards('remove_clause')}>Remove clause</button>
        <button disabled={locked || cardIndex === 0} onClick={() => changeCards('move_up')}>Move up</button>
        <button disabled={locked || cardIndex + 1 >= cards.length} onClick={() => changeCards('move_down')}>Move down</button>
      </div>
    </section>}
    <div className="flex gap-3">
      <button disabled={locked || !draft} onClick={() => void preview()}>{view.run}</button>
      <button disabled={proof.busy || !proof.cursor} onClick={() => void proof.command('accept')}>{view.accept}</button>
      <button disabled={proof.busy || !proof.cursor} onClick={() => void proof.command('stop')}>{view.stop}</button>
    </div>
    <p>No changes are saved before {view.accept}. A conflict keeps your draft.</p>
    {error && <p role="alert">{error}</p>}
    {proof.reply && <pre aria-label={view.results} className="whitespace-pre-wrap break-words">{replyText(proof.reply, proof.solutionNumber)}</pre>}
    {proof.pendingOperation && <button disabled={proof.busy} onClick={() => void proof.resolve()}>{view.resolve}</button>}
    {goal && <details><summary>Prolog goal being submitted</summary><pre className="whitespace-pre-wrap break-words">{goal}</pre></details>}
  </main>
}
