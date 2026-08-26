// The live ledger table — TanStack Table over the store's committed records for one namespace.

import { createColumnHelper, flexRender, getCoreRowModel, useReactTable } from '@tanstack/react-table'
import { useEffect, useState } from 'react'
import type { LiveLedgerRow, TxStatus } from './store'
import { ago, shortHex } from './format'

const chip: Record<TxStatus, { label: string; cls: string }> = {
  history: { label: 'committed', cls: 'bg-teal/10 text-teal-light' },
  pending: { label: 'committing…', cls: 'bg-gold-soft/40 text-teal' },
  applied: { label: 'applied', cls: 'bg-olive/15 text-olive' },
  rejected: { label: 'rejected', cls: 'bg-rose/15 text-rose' },
}

const col = createColumnHelper<LiveLedgerRow>()

export function TxTable({
  rows,
  onSelect,
  selected,
  hasMore,
  onMore,
  loadingMore,
}: {
  rows: LiveLedgerRow[]
  onSelect: (t: LiveLedgerRow) => void
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
    col.display({
      id: 'record',
      header: 'Record',
      cell: (c) => {
        const row = c.row.original
        return row.row_type === 'transaction'
          ? <span className="font-mono text-gray">{shortHex(row.tx_id)}</span>
          : <span className="font-mono text-gold">DTX · {row.phase}</span>
      },
    }),
    col.display({
      id: 'detail',
      header: 'Goal / control',
      cell: (c) => {
        const row = c.row.original
        if (row.row_type === 'control') {
          return (
            <div className="max-w-[26rem]">
              <span className="block truncate font-mono text-[13px] text-teal">
                durable transaction {row.phase}
              </span>
              <span className="mt-0.5 block font-mono text-[11px] text-gray">
                group {shortHex(row.control.group_id)} · {row.control.target?.ns ?? 'invalid target'}
              </span>
            </div>
          )
        }
        return (
          <div className="max-w-[26rem]">
            <span className="block truncate font-mono text-[13px] text-teal">
              {row.goal ?? <span className="italic text-gray">genesis</span>}
            </span>
            {row.effect_count > 0 && (
            <span className="mt-0.5 block truncate text-[11px] font-medium text-gold">
              lifecycle: {row.effect_operations.join(', ')}
            </span>
          )}
            {row.ops > 0 && (
            <span className="mt-0.5 block text-[11px] text-gray">
                {row.ops} operation{row.ops === 1 ? '' : 's'} ·{' '}
                {row.fact_ops} fact change{row.fact_ops === 1 ? '' : 's'} ·{' '}
                {row.ops - row.fact_ops} event{row.ops - row.fact_ops === 1 ? '' : 's'}
            </span>
          )}
          </div>
        )
      },
    }),
    col.display({
      id: 'author',
      header: 'Author',
      cell: (c) => {
        const row = c.row.original
        const author = row.row_type === 'transaction' ? row.author : row.control.author
        return <span className="font-mono text-xs text-gray">{author?.id ?? '—'}</span>
      },
    }),
    col.accessor('time', {
      header: 'Age',
      cell: (c) => <span className="whitespace-nowrap text-xs text-gray">{ago(c.getValue(), now)}</span>,
    }),
    col.display({
      id: 'status',
      header: '',
      cell: (c) => {
        const row = c.row.original
        if (row.row_type === 'control') {
          return <span className="rounded-full bg-gold-soft/40 px-2 py-0.5 text-[11px] font-medium text-teal">committed</span>
        }
        const s = chip[row.status]
        return <span className={`rounded-full px-2 py-0.5 text-[11px] font-medium ${s.cls}`}>{s.label}</span>
      },
    }),
  ]

  const table = useReactTable({
    data: rows,
    columns,
    getCoreRowModel: getCoreRowModel(),
    getRowId: (r) => r.row_id,
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
                  No committed records yet.
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
