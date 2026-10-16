# Correction verification — idle-movement-freeze fix

**Verdict: APPROVE** (conditional only on tests03 + gates02 finishing green, as already running). No new blockers.

## B1 — resolved
`simulation_open/2` now forwards the full fixture (`F#{reference := …}`), so `expires => Expiry` reaches `maps:get(expires,F,…)` in the 3-arity. Dropping `identity` from the 2-arity head is harmless; the 3-arity still requires it. Lease is 300 s → `Idle > 60000` is satisfiable.

Residual, not verifiable offline: if `with_door`'s fixture (or any other 2-arity caller's fixture) carries a `space` or `dependencies` key, the forwarded map now changes the goal text where the old wrapper stripped it. The `can_invoke` rule uses `_` for dependencies so admission would hold, but the focused run is the proof. If tests03 shows an unexpected `denied`/different marks, that is the cause — fix would be `maps:with([namespace,reference,identity,expires],F)` in the wrapper, not a production change.

## B2 — resolved
`{Opened,Expiry} = Open()` removes the collision. Scoping checked: `Before`/`Expiry` inside the fun body are fun-local (no outer binding exists at definition time), so the later `Before = gen_server:call(Pid, status)` is a fresh outer binding, no `badmatch`, no shadow warning. Later discarded `Open()` results are fine.

## Assertions — correct
- `Idle =< Expiry-Opened`: `Opened ≤ T_reply` → holds.
- `Idle >= Expiry-now`: `now ≥ T_reply` → holds.
- Same reasoning for the renewal test's `Before` (fun-local per iteration).

## Fixtures
`gui_socket` and `simulation_socket` command-list branches match the production shape exactly (`[{set_options,#{idle_timeout}}, {text,_}]`). Projection frames never need the gui_prepare/activate auto-ack path, so routing them past it is correct. Extra `simulation_transport_timeout` messages from later `Open()`s stay in the parent mailbox; all receives are selective — harmless.

## Production
Unchanged since approval. Comment now says idle window with absolute expiry authoritative — matches Cowboy semantics.

## Advisories carried over (unchanged, non-blocking)
Window persists after release; `waiting_for_installation` keeps 60 s; `binary_to_integer(Expiry)` re-parse cosmetic.

**Proceed:** take tests03 and gates02 results as the final evidence; commit only on explicit go.