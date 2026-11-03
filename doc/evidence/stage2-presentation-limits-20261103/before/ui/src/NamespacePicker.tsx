// Choosing which ontology a goal is sent to. Namespaces are user-supplied and
// unbounded in practice — a user home is `user:` plus a 64-character digest —
// so a row of tabs stops working as soon as one real name appears. This keeps
// the header a fixed size and makes finding one of many a matter of typing.
import { useEffect, useMemo, useRef, useState } from 'react'
import type { NsSummary } from './api'
import { shortNamespace } from './namespace'

export function NamespacePicker({
  namespaces,
  current,
  onNs,
}: {
  namespaces: NsSummary[]
  current: string | null
  onNs: (ns: string) => void
}) {
  const [open, setOpen] = useState(false)
  const [filter, setFilter] = useState('')
  const box = useRef<HTMLDivElement>(null)
  const search = useRef<HTMLInputElement>(null)

  useEffect(() => {
    if (!open) return
    const onPointer = (event: MouseEvent) => {
      if (box.current && !box.current.contains(event.target as Node)) setOpen(false)
    }
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setOpen(false)
    }
    document.addEventListener('mousedown', onPointer)
    document.addEventListener('keydown', onKey)
    search.current?.focus()
    return () => {
      document.removeEventListener('mousedown', onPointer)
      document.removeEventListener('keydown', onKey)
    }
  }, [open])

  const matches = useMemo(() => {
    const needle = filter.trim().toLowerCase()
    if (!needle) return namespaces
    return namespaces.filter((n) => n.ns.toLowerCase().includes(needle))
  }, [namespaces, filter])

  const choose = (ns: string) => {
    onNs(ns)
    setOpen(false)
    setFilter('')
  }

  const currentSummary = namespaces.find((n) => n.ns === current)

  return (
    <div ref={box} className="relative">
      <button
        type="button"
        onClick={() => setOpen(!open)}
        title={current ?? 'No ontology selected'}
        className="flex max-w-[22rem] items-center gap-2 rounded-lg border border-cream/30 bg-teal-light/40 px-3 py-1.5 text-left transition hover:bg-teal-light"
      >
        <span className="truncate font-mono text-sm">
          {current ? shortNamespace(current) : 'select ontology'}
        </span>
        {currentSummary?.syncing && (
          <span className="shrink-0 text-[10px] text-gold-soft">syncing</span>
        )}
        <span className="shrink-0 text-gold">▾</span>
      </button>
      {open && (
        <div className="absolute top-full left-0 z-30 mt-1 w-[28rem] max-w-[calc(100vw-2rem)] rounded-lg border border-teal-dark/40 bg-cream text-teal shadow-xl">
          <div className="border-b border-teal/15 p-2">
            <input
              ref={search}
              value={filter}
              onChange={(e) => setFilter(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter' && matches.length > 0) choose(matches[0].ns)
              }}
              placeholder="Filter ontologies…"
              spellCheck={false}
              className="w-full rounded-md border border-teal-light/45 bg-white px-2 py-1 font-mono text-sm focus:border-teal-light focus:ring-2 focus:ring-gold/45 focus:outline-none"
            />
          </div>
          <ul className="max-h-72 overflow-y-auto py-1">
            {matches.length === 0 && (
              <li className="px-3 py-2 text-sm text-gray">No ontology matches that.</li>
            )}
            {matches.map((n) => (
              <li key={n.ns}>
                <button
                  type="button"
                  onClick={() => choose(n.ns)}
                  title={n.ns}
                  className={
                    'flex w-full items-baseline gap-2 px-3 py-1.5 text-left transition hover:bg-gold-soft/30 ' +
                    (n.ns === current ? 'bg-gold-soft/45 font-semibold' : '')
                  }
                >
                  {/* The full name wraps rather than truncating: this is where
                      someone confirms they picked the right home. */}
                  <span className="font-mono text-[13px] break-all">{n.ns}</span>
                  {n.syncing && (
                    <span className="ml-auto shrink-0 text-[10px] text-rose">syncing</span>
                  )}
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  )
}
