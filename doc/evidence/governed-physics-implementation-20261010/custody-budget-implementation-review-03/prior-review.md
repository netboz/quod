**Verdict: approve after one small correction in `quod_runtime.erl`.** The patch implements both prior blockers correctly, removes the hidden cap completely, and keeps one owner. Scope 03 ran on exactly the reviewed tree (manifest hashes match), 172 EUnit tests and the client suite passed with true exit 0.

## Blocker

**Post-admission deadline branch withdraws admission but keeps a precise wake basis.** At `quod_runtime.erl:2740` the worker has already had its basis admitted by `resource_selected` (`quod_runtime.erl:300`). If the absolute deadline passes between admission and install, line 2742 now withdraws limits and replies `{error, deadline_exceeded}`, which lands in the non-interrupted clause at `quod_runtime.erl:1116`. The basis stays exact, nothing re-queues the key, so custody admission stays withdrawn until a root commit touches the selector's own reads. That contradicts the stated contract that every interrupted or deadline path keeps the conservative dependency. The new test only reaches the `start_resource` branch at `quod_runtime.erl:1091` via a zero budget, not this one.

Fix within the existing owner: return `{interrupted, {error, deadline_exceeded}}` at line 2742, exactly as line 2721 does, and delete the `install_resource(..., {error, deadline_exceeded})` arm. The already tested interrupted clause then withdraws and sets the unknown basis. The window is not deterministically testable; sharing the tested path is the right closure.

## Nonblockers

- **Withdrawal inside the runtime owner is safe but silent.** `quod_runtime.erl:1104` makes a bounded 5 s call that can fsync. No deadlock: journal reconciliation runs in a spawned worker (`quod_effect_journal.erl:499`) and `effect_frontier` is called only there with a 1 s timeout. Precedent exists (`release_direct_effects`). But the result is discarded, so a timed-out withdraw leaves old admission live with no record. Fold `{error, unavailable}` into `resource_failures` or log it.
- **Liveness consequence of the accepted fail-closed design.** A notice starved in the queue past its 30 s deadline (`quod_runtime.erl:2505`) or a budget-killed selector withdraws admission until the next root commit of any kind. Observable via `resource_failures` and the configured gauge reading 0. Put this in the deployment notes.
- **Stage-time `unavailable` is a new error class with inconsistent mapping.** Reserve-time unavailability becomes `effect_journal_unavailable` (`quod_prolog.erl:5111`) but stage-time passes through raw at `quod_prolog.erl:5105` and crosses scopes as `{ontology_unreachable, Ns}` (`quod_prolog.erl:3384`). One clause mapping stage `unavailable` to the reserve class would unify them. Same passthrough in `quod_proof_session.erl:663`.
- **Byte limit is not exported to metrics.** `quod_metrics.erl:775` reads only the count. The plan asked for relevant metrics; add a limit/unlimited gauge pair or state the deferral.
- **Selection cause lost when the journal is absent.** `quod_runtime.erl:2830` returns `{error, unavailable}` in place of the original selection error.
- **JS error carries only a message.** Attaching `resource`, `actual` and `limit` to the error object would serve programmatic callers. Optional.
- **`doc/README.md` is modified in the working tree but absent from the patch and frozen tree.** Include it in the commit scope.

## Verified

- Old cap and API fully gone: no `effect_custody_capacity`, `configure_capacity`, `capacity/0` or the 256 KiB macro remain. `initial_content_too_large` survives only for the genuine 192 KiB initial-diff bound at `quod_ontology.erl:880`. Block and transaction bounds in `quod_ingress_limits.hrl` are untouched.
- Stage order is validate, encode, digest, then bytes (`quod_effect_journal.erl:560`). Invalid preparations are never reported as over budget. Reservation survives a byte refusal and is released by every caller.
- Binding never re-checks bytes; `trim_terminal_rows` is count-only and a no-op when unconfigured. Tightening to `{0, 0}` after stage still binds the group (new fixture). Recovery row checks validate hashes only.
- Snapshot version 8 persists `unconfigured`, so withdrawn admission is durable. Version 7 is rejected explicitly. Unchanged withdrawals do not persist.
- Count pressure remains `busy` and retryable in all lanes. The byte reason is in the closed scope catalog with strict uint64 and `Actual > Limit` checks, and HTTP reports exact strings with 413.
- The remote `submit_plan` wire path never stages effect plans (`quod_prolog.erl:6054` refuses them), so the typed reason always travels as a scope error. The `bad_plan` collapse in `submit_outcome` is not reachable for this error.
- Authorization unchanged: the selector is public, the setter is not, and the node-context fixtures cover direct-context refusal.
- Full release gates, candidate cold refound with ledger and `direct_effects.qej` wipe, and live acceptance remain outstanding as stated.
