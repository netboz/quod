// The live transaction table — TanStack Table over the store's rows for one namespace.

import { createColumnHelper, flexRender, getCoreRowModel, useReactTable } from '@tanstack/react-table'
import { useEffect, useState } from 'react'
import type { LiveTx, TxStatus } from './store'
import { ago, shortHex } from './format'

const chip: Record<TxStatus, { label: string; cls: string }> = {
  history: { label: 'committed', cls: 'bg-teal/10 text-teal-light' },
  pending: { label: 'committing…', cls: 'bg-gold-soft/40 text-teal' },
  applied: { label: 'applied', cls: 'bg-olive/15 text-olive' },
  rejected: { label: 'rejected', cls: 'bg-rose/15 text-rose' },
}

const col = createColumnHelper<LiveTx>()

export function TxTable({
  rows,
  onSelect,
  selected,
  hasMore,
  onMore,
  loadingMore,
}: {
  rows: LiveTx[]
  onSelect: (t: LiveTx) => void
  selected: string | null
  hasMore: boolean
  onMore: () => void
  loadingMore: boolean
}) {
  // one ticking clock for the whole table's ages
  const [now, setNow] = useState(Date.now())
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(t)
  }, [])

  const columns = [
    col.accessor('height', {
      header: 'Height',
      cell: (c) => <span className="font-mono text-teal-light">#{c.getValue()}</span>,
    }),
    col.accessor('tx_id', {
      header: 'Tx',
      cell: (c) => <span className="font-mono text-gray">{shortHex(c.getValue())}</span>,
    }),
    col.accessor('goal', {
      header: 'Goal',
      cell: (c) => (
        <div className="max-w-[26rem]">
          <span className="block truncate font-mono text-[13px] text-teal">
            {c.getValue() ?? <span className="italic text-gray">genesis</span>}
          </span>
          {c.row.original.effect_count > 0 && (
            <span className="mt-0.5 block truncate text-[11px] font-medium text-gold">
              lifecycle: {c.row.original.effect_operations.join(', ')}
            </span>
          )}
          {c.row.original.ops > 0 && (
            <span className="mt-0.5 block text-[11px] text-gray">
              {c.row.original.ops} operation{c.row.original.ops === 1 ? '' : 's'} ·{' '}
              {c.row.original.fact_ops} fact change{c.row.original.fact_ops === 1 ? '' : 's'} ·{' '}
              {c.row.original.ops - c.row.original.fact_ops} event{c.row.original.ops - c.row.original.fact_ops === 1 ? '' : 's'}
            </span>
          )}
        </div>
      ),
    }),
    col.accessor('author', {
      header: 'Author',
      cell: (c) => <span className="font-mono text-xs text-gray">{c.getValue()?.id ?? '—'}</span>,
    }),
    col.accessor('time', {
      header: 'Age',
      cell: (c) => <span className="whitespace-nowrap text-xs text-gray">{ago(c.getValue(), now)}</span>,
    }),
    col.accessor('status', {
      header: '',
      cell: (c) => {
        const s = chip[c.getValue()]
        return <span className={`rounded-full px-2 py-0.5 text-[11px] font-medium ${s.cls}`}>{s.label}</span>
      },
    }),
  ]

  const table = useReactTable({
    data: rows,
    columns,
    getCoreRowModel: getCoreRowModel(),
    getRowId: (r) => r.tx_id,
  })

  return (
    <div className="overflow-hidden rounded-xl border border-teal/30 bg-white/90 shadow-sm">
      <div className="overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead>
            {table.getHeaderGroups().map((hg) => (
              <tr key={hg.id} className="border-b border-teal-dark/40 bg-teal text-cream">
                {hg.headers.map((h) => (
                  <th key={h.id} className="px-4 py-2.5 text-[11px] font-semibold tracking-wider text-cream/75 uppercase">
                    {flexRender(h.column.columnDef.header, h.getContext())}
                  </th>
                ))}
              </tr>
            ))}
          </thead>
          <tbody>
            {table.getRowModel().rows.map((row) => (
              <tr
                key={row.id}
                onClick={() => onSelect(row.original)}
                className={
                  'cursor-pointer border-b border-gray/10 transition-colors last:border-0 hover:bg-cream ' +
                  (row.original.live ? 'tx-flash ' : '') +
                  (selected === row.id ? 'bg-gold-soft/20' : '')
                }
              >
                {row.getVisibleCells().map((cell) => (
                  <td key={cell.id} className="px-4 py-2.5">
                    {flexRender(cell.column.columnDef.cell, cell.getContext())}
                  </td>
                ))}
              </tr>
            ))}
            {rows.length === 0 && (
              <tr>
                <td colSpan={6} className="px-4 py-10 text-center text-sm text-gray">
                  No transactions yet — commit one from the console below.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
      {hasMore && (
        <div className="border-t border-gray/15 p-2 text-center">
          <button
            onClick={onMore}
            disabled={loadingMore}
            className="rounded-lg px-4 py-1.5 text-sm font-medium text-teal-light hover:bg-cream disabled:opacity-50"
          >
            {loadingMore ? 'Loading…' : 'Load older transactions'}
          </button>
        </div>
      )}
    </div>
  )
}
