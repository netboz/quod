import { useEffect, useEffectEvent, useMemo, useRef, useState } from 'react'
import { useSignedSession } from './session-context'
import { useProofCursor, replyText } from './Console'
import { codeForm } from '../../client/src/world.js'
import type { WorldScene } from '../../client/src/world-scene.js'
import type { EidolonWorkspace } from '../../client/src/world.js'
import { formatTerm } from '../../client/src/prolog-term.js'
import type { PrologTerm } from '../../client/src/prolog-term.js'
import { readCodePredicates, readCodeSource, readCodeState, prepareCodeEdit, predicateIndicator, readCodeClauses, clausesSource } from '../../client/src/prolog-edit.js'
import { PrologText } from './PrologText'
import { b64url } from '../../client/src/key-provider.js'

import type { ClauseCard } from '../../client/src/prolog-edit.js'

type Draft = { baseline: string; source: string; cards?: ClauseCard[] }

function editError(reason: unknown) {
  const reasons = reason && typeof reason === 'object' && 'reasons' in reason && Array.isArray(reason.reasons) ? reason.reasons : []
  return [String(reason), ...reasons].join('\n')
}

// Catalogue reads and local drafts meet in one choice list. A late initial
// read must not erase a predicate restored from an unresolved signed edit.
function mergePredicates(...catalogues: PrologTerm[][]) {
  const choices = new Map<string, PrologTerm>()
  for (const predicate of catalogues.flat()) choices.set(formatTerm(predicate), predicate)
  return [...choices.values()]
}

type EditorProps = { workspace: EidolonWorkspace; onClose: () => void; onRefresh: () => Promise<void>; scene: WorldScene | null; visible: boolean }

export function PrologEditor(props: EditorProps) {
  const { identity, agent } = useSignedSession()
  const scope = JSON.stringify([identity && b64url(identity.networkId), identity && b64url(identity.provider.publicKey),
    agent?.namespace, String(agent?.anchor ?? ''), agent?.instanceText, props.workspace.target, props.workspace.tools])
  return <ScopedEditor key={`${scope}:${props.workspace.selection ? formatTerm(props.workspace.selection) : 'all'}`} storageKey={`quod.prolog-draft.v1:${scope}`} {...props} />
}

function ScopedEditor({ workspace, onClose, onRefresh, scene, visible, storageKey }: EditorProps & { storageKey: string }) {
  const binding = workspace.selection && formatTerm(workspace.selection) !== 'all' ? formatTerm(workspace.selection) : ''
  const [bindingAvailable, setBindingAvailable] = useState(!binding)
  const [savedLocal] = useState(() => {
    try {
      const raw = localStorage.getItem(storageKey)
      if (!raw) return { selected: '', drafts: {} as Record<string, Draft>, error: null }
      const saved = JSON.parse(raw)
      if (typeof saved.selected !== 'string' || !saved.drafts || Object.values(saved.drafts).some((draft: unknown) =>
        !draft || typeof (draft as Draft).baseline !== 'string' || typeof (draft as Draft).source !== 'string')) throw new Error('Invalid saved draft')
      return { selected: saved.selected as string, drafts: saved.drafts as Record<string, Draft>, error: null }
    } catch (reason) { return { selected: '', drafts: {} as Record<string, Draft>, error: String(reason) } }
  })
  const [storageError, setStorageError] = useState<string | null>(savedLocal.error)
  const { identity, agent } = useSignedSession()
  const view = codeForm(workspace.view)
  const [refreshFailed, setRefreshFailed] = useState(false)
  const editable = view.editable && !refreshFailed && bindingAvailable
  const proof = useProofCursor(agent?.namespace ?? '', String(agent?.anchor ?? ''), JSON.stringify(['prolog', workspace.target]))
  const [predicates, setPredicates] = useState<PrologTerm[]>([])
  const [selected, setSelected] = useState(binding || savedLocal.selected)
  const [newPredicate, setNewPredicate] = useState('')
  const [layout, setLayout] = useState<'text' | 'cards'>('text')
  const [cardIndex, setCardIndex] = useState(0)
  const [drafts, setDrafts] = useState<Record<string, Draft>>(savedLocal.drafts)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [goal, setGoal] = useState('')
  const [refreshing, setRefreshing] = useState(false)
  const refreshingNow = useRef(false)
  const live = useRef(true)
  const pending = useRef(false)
  const submitted = useRef<{ indicator: string; source: string } | null>(null)
  const indicator = predicates.find(predicate => formatTerm(predicate) === selected)
  const draft = bindingAvailable ? drafts[selected] : undefined
  const selection = selected ? indicator : null
  const locked = loading || refreshing || proof.busy || proof.cursor !== null || proof.pendingOperation !== null

  useEffect(() => {
    // Keep only local changes, scoped to exact network, signer, actor and
    // anchored target. The operation journal remains the sole write custody.
    if (savedLocal.error) return
    try {
      const dirty = Object.fromEntries(Object.entries(drafts).filter(([, draft]) => draft.source !== draft.baseline))
      if (Object.keys(dirty).length) localStorage.setItem(storageKey, JSON.stringify({ selected, drafts: dirty }))
      else localStorage.removeItem(storageKey)
      setStorageError(null)
    } catch (reason) { setStorageError(String(reason)) }
  }, [drafts, selected, storageKey, savedLocal.error])

  useEffect(() => {
    setPredicates(previous => mergePredicates(previous, Object.keys(savedLocal.drafts).filter(Boolean).map(predicateIndicator)))
  }, [savedLocal])

  const refreshSavedDrafts = useEffectEvent(() => {
    // A newly authorized representation refreshes saved contents. Local edits
    // keep their original baseline; refresh never silently rebases a draft.
    if (!proof.cursor && !proof.pendingOperation && !pending.current) {
      setDrafts(previous => Object.fromEntries(Object.entries(previous)
        .filter(([, draft]) => draft.source !== draft.baseline)))
      setLayout('text')
    }
  })

  useEffect(() => {
    let current = true
    live.current = true
    setRefreshFailed(false)
    refreshSavedDrafts()
    if (identity && agent) {
      void readCodePredicates(identity, agent, workspace).then(items => {
        if (current) {
          setBindingAvailable(true)
          setPredicates(previous => mergePredicates(items, previous))
        }
      }).catch(reason => { if (current) { setBindingAvailable(false); setError(editError(reason)) } })
    }
    return () => { current = false; live.current = false }
  }, [identity, agent, workspace])

  useEffect(() => {
    const controller = new AbortController()
    if (identity && agent && bindingAvailable && !draft && (!selected || indicator)) {
      setLoading(true)
      const read = indicator ? readCodeSource(identity, agent, workspace, indicator)
        : readCodeState(identity, agent, workspace, controller.signal)
      void read.then(source => {
        if (!controller.signal.aborted) setDrafts(previous => ({ ...previous, [selected]: { source, baseline: source } }))
      }).catch(reason => { if (!controller.signal.aborted) setError(editError(reason)) })
        .finally(() => { if (!controller.signal.aborted) setLoading(false) })
    }
    return () => controller.abort()
  }, [identity, agent, workspace, indicator, selected, draft, bindingAvailable])

  const refresh = async () => {
    if (locked || refreshingNow.current || pending.current || !proof.canEdit()) return
    refreshingNow.current = true
    setRefreshing(true)
    setError(null)
    try {
      await onRefresh()
    } catch (reason) {
      if (live.current) { setRefreshFailed(true); setError(editError(reason)) }
    } finally {
      refreshingNow.current = false
      if (live.current) setRefreshing(false)
    }
  }

  const discardDraft = async () => {
    if (!identity || !agent || locked || pending.current || !proof.canEdit()) return
    pending.current = true
    setLoading(true)
    try {
      const source = indicator ? await readCodeSource(identity, agent, workspace, indicator)
        : await readCodeState(identity, agent, workspace)
      if (!live.current) return
      setDrafts(previous => ({ ...previous, [selected]: { source, baseline: source } }))
      setLayout('text')
      setError(null)
    } catch (reason) { if (live.current) setError(editError(reason)) }
    finally { pending.current = false; if (live.current) setLoading(false) }
  }

  useEffect(() => {
    const saved = proof.recoveryContext
    if (saved && typeof saved.indicator === 'string' && typeof saved.source === 'string' && typeof saved.baseline === 'string') {
      const indicator = saved.indicator
      const source = saved.source
      const baseline = saved.baseline
      if (!binding || binding === indicator) setSelected(indicator)
      if (indicator) setPredicates(previous => mergePredicates(previous, [predicateIndicator(indicator)]))
      setDrafts(previous => ({ ...previous, [indicator]: { source, baseline } }))
      submitted.current = { indicator, source }
    }
  }, [proof.recoveryContext])

  useEffect(() => {
    // Only a positive terminal result advances the opened baseline. Pending
    // or unknown Accept outcomes keep the original draft and its evidence.
    const saved = submitted.current
    if (saved && proof.reply && 'result' in proof.reply && (proof.reply.result === 'ok' || (proof.reply.result === 'recovered' && proof.reply.status === 'committed'))) {
      setDrafts(previous => {
        const dirty = Object.fromEntries(Object.entries(previous)
          .filter(([key, draft]) => key !== saved.indicator && draft.source !== draft.baseline))
        return { ...dirty, [saved.indicator]: { baseline: saved.source, source: saved.source } }
      })
      submitted.current = null
    }
  }, [proof.reply])

  const preview = async () => {
    if (!editable || !identity || !agent || (selected && !indicator) || !draft || pending.current || !proof.canEdit()) return
    pending.current = true
    setLoading(true)
    setError(null)
    try {
      const edit = await prepareCodeEdit(identity, agent, workspace, selection ?? null, draft.baseline, draft.source)
      if (!live.current) return
      setGoal(edit)
      submitted.current = { indicator: selected, source: draft.source }
      await proof.run(edit, { indicator: selected, baseline: draft.baseline, source: draft.source })
    } catch (reason) { if (live.current) setError(editError(reason)) }
    finally { pending.current = false; if (live.current) setLoading(false) }
  }

  const changeLayout = async (next: string) => {
    if (!editable || !selected || locked || !proof.canEdit() || pending.current || !draft) return
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
    } catch (reason) { if (live.current) setError(editError(reason)) }
    finally { pending.current = false; if (live.current) setLoading(false) }
  }
  const changeCards = (action: string, value = '') => {
    if (!editable || locked || !proof.canEdit() || pending.current || !draft?.cards) return
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
    if (binding) return;
    if (!editable || locked || !proof.canEdit()) return
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
    } catch (reason) { setError(editError(reason)) }
  }
  const edit = (role: string, value: string) => {
    if (pending.current || !proof.canEdit() || loading) return
    if (role === 'predicate') { if (binding) return; setSelected(value); setLayout('text'); setCardIndex(0); return }
    if (!editable) return
    if (role === 'layout') void changeLayout(value)
    if (role === 'clause') setCardIndex(Number(value))
    if (role === 'head' || role === 'body') changeCards(role, value)
    if (role === 'new_predicate' && !binding) setNewPredicate(value)
    if (role === 'source' && draft) setDrafts(previous => ({ ...previous, [selected]: { baseline: draft.baseline, source: value } }))
  }
  const cards = draft?.cards ?? []
  const card = cards[cardIndex]
  const conflict = proof.reply && 'error' in proof.reply && proof.reply.error.replace(/^Error: /, '') === 'conflict_retry'
  const proofResult = conflict
    ? `Couldn't save: the source or permissions changed since your preview. Your draft is safe. ${proof.cursor ? `Choose “${view.stop}”, then refresh` : 'Refresh'} the current state before trying again.`
    : replyText(proof.reply, proof.solutionNumber)
  const result = [error, proofResult].filter(Boolean).join('\n')
  const panelView = useMemo(() => ({ ...workspace.view, fields: workspace.view.fields.flatMap(field => field.role !== 'source' ? [field]
        : !editable ? [{ ...field, kind: 'bindings' }] : [
        ...(selected ? [{ kind: 'catalogue_selection', role: 'layout', label: 'Code layout' }] : []),
        ...(layout === 'text' ? [field] : [
          { kind: 'catalogue_selection', role: 'clause', label: 'Clause order' },
          { kind: 'text_box', role: 'head', label: 'Head' },
          { kind: 'editor', role: 'body', label: 'Body (empty for a fact)' },
          ...[['add_clause', 'Add clause'], ['remove_clause', 'Remove clause'], ['move_up', 'Move up'], ['move_down', 'Move down']]
            .map(([role, label]) => ({ kind: 'button', role, label })),
        ]),
      ]) }), [workspace.view, editable, selected, layout])
  useEffect(() => () => { scene?.setWorkspace(null) }, [scene])
  useEffect(() => {
    scene?.setWorkspace(visible ? {
      view: panelView, scope: `${workspace.target.namespace}\nGenesis: ${b64url(workspace.target.anchor)}`,
      values: { predicate: selected, new_predicate: newPredicate, source: draft?.source ?? '', results: result,
        layout, clause: String(cardIndex), head: card?.head ?? '', body: card?.body ?? '' },
      choices: { layout: [{ value: 'text', label: 'Text' }, { value: 'cards', label: 'Clause cards' }],
        clause: cards.map((card, index) => ({ value: String(index), label: `${index + 1}. ${card.head}` })), predicate: [{ value: '', label: 'Complete current state' }, ...predicates.map(predicate => { const value = formatTerm(predicate); return { value, label: value } })] },
      locked,
      enabled: { run: editable && !locked && !!draft, accept: editable && !proof.busy && !!proof.cursor,
        stop: editable && !proof.busy && !!proof.cursor,
        create: editable && !binding && !locked && !!newPredicate.trim(), resolve: editable && !proof.busy && !!proof.pendingOperation,
        add_clause: editable && !locked, remove_clause: editable && !locked && !!card,
        move_up: editable && !locked && cardIndex > 0,
        move_down: editable && !locked && cardIndex + 1 < cards.length },
      edit,
      invoke: role => { if (role === 'run') void preview(); else if (role === 'create') createPredicate(); else if (role === 'resolve') void proof.resolve(); else if (role === 'accept' || role === 'stop') void proof.command(role);
        else if (['add_clause', 'remove_clause', 'move_up', 'move_down'].includes(role)) changeCards(role) },
      close: onClose,
    } : null)
  })

  return <main className="prolog-editor mx-auto flex min-h-screen max-w-7xl flex-col gap-5 p-8">
    <header className="flex items-start justify-between gap-4">
      <div><h1 className="text-2xl font-semibold">{view.title}</h1>
        <p className="break-all font-mono text-sm">{workspace.target.namespace}<br />Genesis: {b64url(workspace.target.anchor)}</p></div>
      <button className="rounded-lg border px-4 py-2" onClick={onClose}>Return to lobby</button>
    </header>
    <p>The complete current state includes stored facts, rules and shared policy. {editable ? 'Edit this text as one atomic change, or select a predicate lens.' : 'This is a read-only representation.'}</p>
    <p className="text-sm">Stored clauses are reconstructed in predicate order. Original comments, spacing and variable names are not retained; drafts keep your text. Compiled engine procedures and generated following clauses are omitted. Editing this view grants no additional content or policy permission.</p>
    {storageError && <p role="alert">Local draft storage failed: {storageError}. Keep a copy before closing or reloading.</p>}
    <button disabled={locked} onClick={() => void refresh()}>{refreshing ? 'Refreshing…' : 'Refresh current state'}</button>
    <p className="text-sm">Refresh reloads saved contents and access. Unsaved edits keep their original baseline.</p>
    {draft && draft.source !== draft.baseline && <button disabled={locked} onClick={() => void discardDraft()}>Discard draft and reload</button>}
    <label>{view.predicate} <select value={selected} disabled={locked || !!binding} onChange={event => edit('predicate', event.target.value)}>
      <option value="">Complete current state</option>
      {predicates.map(predicate => { const name = formatTerm(predicate); return <option key={name} value={name}>{name}</option> })}
    </select></label>
    {editable && <><label>{view.new_predicate} <input aria-label={view.new_predicate} value={newPredicate} disabled={locked}
      onChange={event => edit('new_predicate', event.target.value)} />
      <button disabled={locked || !!binding || !newPredicate.trim()} onClick={createPredicate}>{view.create}</button></label>
    <label>Code layout <select aria-label="Code layout" value={layout} disabled={locked || !draft || !selected}
      onChange={event => void changeLayout(event.target.value)}><option value="text">Text</option><option value="cards">Clause cards</option></select></label></>}
    {layout === 'text' ? <PrologText label={view.source} value={draft?.source ?? ''}
      readOnly={!editable} disabled={locked || !draft} onChange={value => edit('source', value)} /> : <section aria-label="Clause cards" className="flex flex-col gap-3 rounded-xl border p-4">
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
    {editable && <><div className="flex gap-3">
      <button disabled={locked || !draft} onClick={() => void preview()}>{view.run}</button>
      <button disabled={proof.busy || !proof.cursor} onClick={() => void proof.command('accept')}>{view.accept}</button>
      <button disabled={proof.busy || !proof.cursor} onClick={() => void proof.command('stop')}>{view.stop}</button>
    </div>
    {draft && draft.source !== draft.baseline && <details><summary>Review local changes against opened baseline</summary>
      <div className="grid gap-4 md:grid-cols-2"><section><h2>Opened baseline</h2><pre className="whitespace-pre-wrap break-words">{draft.baseline}</pre></section>
        <section><h2>Local draft</h2><pre className="whitespace-pre-wrap break-words">{draft.source}</pre></section></div>
    </details>}
    <p>No changes are saved before {view.accept}. A conflict keeps your draft.</p>
    </>}
    {error && <p role="alert">{error}</p>}
    {editable && proof.reply && <pre aria-label={view.results} className="whitespace-pre-wrap break-words">{proofResult}</pre>}
    {editable && conflict && <details><summary>Technical details</summary><pre>{replyText(proof.reply, proof.solutionNumber)}</pre></details>}
    {editable && proof.pendingOperation && <button disabled={proof.busy} onClick={() => void proof.resolve()}>{view.resolve}</button>}
    {editable && goal && <details><summary>Prolog goal being submitted</summary><pre className="whitespace-pre-wrap break-words">{goal}</pre></details>}
  </main>
}
