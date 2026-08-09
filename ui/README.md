# quod explorer — frontend

React + TypeScript + Vite + Tailwind + TanStack (Query/Table). The **production
bundle is committed into `priv/explorer/`**, where the node's cowboy listener
(`quod_explorer`) serves it — building the Erlang release needs no node tooling.

```bash
npm install
npm run dev     # HMR dev server; proxies /api and /ws to a node on 127.0.0.1:14569
npm run build   # tsc + vite build → ../priv/explorer  (commit the output)
npm run lint    # oxlint
```

The panel is opt-in on a node (`explorer.enabled`, loopback by default — see
`quod_schema`). Data flow: REST reads (`/api/summary`, `/api/txs`, `/api/tx`,
`/api/block`), a prove console (`POST /api/prove`, reads answer / writes commit),
and the `/ws` stream fusing target-explicit `{committed, Ns, Slot, Entry}` block
frames with per-transaction `applied_live` events. Palette:
`doc/BBSVX Palette.pdf` — don't invent colors.

The summary distinguishes the **finality head** (`committed+1`) from the next
proposal slot (`approved+1`). The consensus card shows "Next proposer" and
`leader(approved+1)` while a proposal slot is open. While finality blocks the
pipeline, it switches to "Finality leader" and `leader(committed+1)`, with the
oldest finality slot and watchdog phase in the subtitle.
