# quod explorer — frontend

React + TypeScript + Vite + Tailwind + TanStack (Query/Table). The **production
bundle is committed into `priv/explorer/`**, where the read-only Explorer and
TLS client listeners serve it — building the Erlang release needs no node tooling.

```bash
npm install
npm run dev     # HMR dev server; proxies /api and /ws to a node on 127.0.0.1:14569
npm run build   # tsc + vite build → ../priv/explorer  (commit the output)
npm run lint    # oxlint
```

Ledger browsing remains available on the optional, read-only Explorer listener.
The interactive console is served at `/explorer/` on the TLS client listener:
it uses the same encrypted browser key, login, signed-goal endpoint, and cursor
owner as the world client. There is no Explorer-specific proof or ACL route.
A displayed answer is provisional: Accept seals it and commits staged writes;
Stop discards them. Ordinary Prolog writes survive Next as normal, while
`transaction/1` is the explicit rollback boundary. Declared lifecycle actions
remain one-shot. The `/ws` stream fuses
target-explicit `{committed, Ns, Slot, Entry}` block frames with per-transaction
`applied_live` events. Palette:
`doc/BBSVX Palette.pdf` — don't invent colors.

History URLs default to live-owner snapshots. Append `mode=offline` explicitly
to inspect a stopped ontology; there is no live-failure disk fallback. The same
`explorer.read_budget_ms` setting (default 30 seconds) covers each HTTP history
operation and the WebSocket's optional Finalize/Prepare enrichment. The latter
stays present when its live-owner snapshot is available; unavailable enrichment
does not suppress the committed block event. The deadline never schedules a
retry, and synchronous disk I/O may finish after it before the request can
return an unavailable result and close its handle.

The summary distinguishes the **finality head** (`committed+1`) from the next
proposal slot (`approved+1`). The consensus card shows "Next proposer" and
`leader(approved+1)` while a proposal slot is open. While finality blocks the
pipeline, it switches to "Finality leader" and `leader(committed+1)`, with the
oldest finality slot and watchdog phase in the subtitle.
