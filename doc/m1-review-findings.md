# M1 content-layer — code review findings

> **Historical record.** Dated findings from the **M1** review of the *Raft* content layer
> (`quod_ledger`), since replaced by the **DispersedSimplex** consensus (`quod_simplex`). Kept as-is;
> module/protocol names below refer to the retired Raft implementation.

Max-effort multi-agent review (2026-06-26) of the M1 content layer: 72 candidates →
**29 verified** (22 CONFIRMED, 7 PLAUSIBLE). This is the complete record. Status
key: **[FIXED]** addressed this session · **[M2]** pinned for the M2 pass (an
inline `%% REVIEW(M2):` note marks the site) · **[NOTE]** acknowledged / by design.

The unifying insight: M1 is single-node and single-threaded, so the **OCC layer
never fires** and most concurrency findings are *dormant* until M2. The live M1
bugs are all in the **startup / restart / failure** paths — which the happy-path
e2e test didn't exercise.

## Real bugs (live in M1)

1. **[FIXED] `quod_prolog.erl:119` — ETS read-set table leak.** The read-set table
   (owned by the long-lived gen_server) was deleted only on the `{succeed,…}`
   branch; `fail`/`error`/`EXIT` leaked one table each → eventual `system_limit`
   crash. The bare `catch` also hid crashes. → `try/after` cleanup on all paths;
   narrowed catch.
2. **[FIXED] `quod_prolog.erl:164` + `quod_ledger.erl:190` — `apply_gap` crash on a
   prolog-only restart with a concurrent write.** A new append's `apply_block(N+1)`
   could hit a fresh kb (`applied=0`) before the async rebuild reset the cursor →
   `error({apply_gap})`, and `apply_loop` had no `try/catch` so it crashed
   `quod_ledger` too. → readiness gate + `apply_block` returns `{behind, Applied}` and
   `apply_loop` resyncs instead of crashing.
3. **[FIXED] `quod_prolog.erl:80` — `prove` served before rebuild completes.**
   Rebuild was a best-effort async cast with no readiness gate → a `prove` in the
   restart window ran against an empty kb. Spec §4.6 requires rebuild before serving
   proves. → `ready` flag; `quod_ledger` signals `mark_ready` after catch-up; `prove`
   returns `{error, rebuilding}` until then (this also removes a rebuild-vs-write
   deadlock).
4. **[FIXED] `quod_prolog.erl:144` — a write "fails" but takes effect.** A 5s append
   timeout replied `{error,…}` *without parking*, but `quod_ledger` could still
   commit+apply. → park before submit; keep parked on ambiguous process/transport
   loss; if the caller deadline expires before finality, return
   `{error, {outcome_unknown, TxId}}` rather than falsely claiming failure.
5. **[FIXED] `quod_prolog.erl:173` — parked caller never replied.** If the block
   never reached `apply_block`, `From` hung to its 35s client timeout (no TTL). →
   per-tx TTL eviction (same mechanism as #4).
6. **[FIXED] `quod_ledger.erl:190` — `commits` counted rejected blocks; no `try/catch`
   around `apply_block`.** Verdict was discarded and `commits` bumped
   unconditionally. → bump only on `ok`; resync on `{behind,_}`; guard the call.

## Correctness subtleties — dormant in M1, **pinned for M2 (concurrency)**

7. **[M2] `quod_erlog_db_local_prove.erl:212` + `:147` — OCC false-negatives.** The
   "skip if locally modified" rule, and the abolished branch never recording, mean a
   write that retracts/abolishes a functor records no read-dependency on it → a
   concurrent change goes undetected. Belongs with the M2 OCC + per-fact-granularity
   rework (design-doc §12 #2).
8. **[FIXED] `quod_erlog_db_local_prove.erl:162` — OCC false-positive.**
   `get_procedure_type` (metadata) went through `get_procedure`, recording a content
   dependency for `predicate_property`/`current_predicate`. → type check reads the
   committed type directly, no read recording.

## Robustness — mostly M2-coupled

9. **[M2] `quod_ledger_store.erl:119` — `write_meta` omits the post-rename dir-fsync.**
   A power-cut can lose a vote → double-vote risk. Only matters once M2 has *real
   elections* (1-voter never has a contested vote).
10. **[FIXED] `quod_prolog.erl:204` — global atom per namespace + named-table restart
    race.** `kb_table` minted a permanent atom and used a named ETS table (re-create
    race on rapid restart). → switched the committed kb to **`erlog_db_dict`**
    (functional, threaded through `#s.est`): no per-namespace named ETS table and no
    global atom at all.
11. **[M2] `quod_ledger.erl:147` — `become_leader` skips the Figure-8 `noop` block.**
    Benign at 1-voter (no prior-term uncommitted entries); **required** for M2's
    multi-voter commit guard. Goes in with the real election path.
12. **[FIXED] `quod_metrics.erl:94` — raw binary `Ns` as a prometheus label.** A
    non-printable namespace breaks `/metrics`. → label is a safe string.
13. **[M2] `quod_ledger_store.erl:282` — `scan_log` trusts CRC-valid frames without
    checking index contiguity/monotonicity.** Defensive; low stakes at 1-voter.
14. **[M2] `quod_erlog_db_local_prove.erl:91` — `new/1` drops `assert_hooks`/
    `retract_hooks` on the wrapped `out_db`.** No hooks are configured in M1; latent
    if erlog hooks are ever used.
15. **[M2] `quod_erlog_db_local_prove.erl:123` — local/committed tag separation is by
    numeric range (`1_000_000`).** Collision only if one functor ever accumulates a
    million committed clauses; latent.

## Efficiency — fine at M1 scale, **M2**

16. **[M2] `quod_ledger.erl:115` — in-memory `#d.log` duplicates the store's index; the
    hot path is O(n²)** (`++`/`lists:last`/`keyfind` per op). Rework when logs grow
    (the store already has an O(1) index).
17. **[M2] `quod_erlog_db_local_prove.erl:113` — `assertz` `++` is O(M²)** for M
    asserts to one functor; `apply_ops` re-fetches the full clause list per op.
18. **[M2] `quod_prolog.erl:119` — a fresh public ETS table is created/torn down per
    `prove`** (the read-set is tiny + single-process). Tie-in with the #1 leak fix;
    a per-engine reused table is the M2 form.

## Cleanup

19. **[FIXED] `quod_prolog.erl:59` — dead `replay_reset/2`** (left after the rebuild
    fix). Removed.
20. **[FIXED] `quod_prolog.erl:149` — dead `{error,conflict_retry}`/`{error,busy}`
    clauses** in `submit_write`; `quod_ledger:append` never returns those. Removed.
21. **[FIXED] `quod_prolog.erl:89` — `proves` counter not bumped on the `{error,_}`
    branch nor on writes.** → counted consistently.
22. **[FIXED] `quod_diff.erl:80` — `clause_present/5` + `find_tag/5` are the same
    scan.** → `clause_present` defined in terms of `find_tag`.
23. **[FIXED] `quod_diff.erl:52` — `functor_of/1` re-implements `erlog_int:functor/1`**
    (already exported, same shape). → call erlog's.
24. **[FIXED] `quod_ledger_store.erl:243` — hand-rolled URL-safe base64.** → OTP native
    `base64:encode(_, #{mode => urlsafe, padding => false})`.

## By design / accepted

25. **[NOTE] `quod_diff.erl:27` — op bodies carry erlog's well-formed `{Body,HasCut}`
    shape.** Deliberate (greenfield, no compat): the overlay produces it, `apply_ops`
    stores it, `functor_hash` consumes it — internally consistent. erlog is SHA-pinned.
26. **[NOTE] `quod_erlog_db_local_prove.erl:68` — `functor_ops` collapses
    asserta/assertz order + duplicate multiplicity.** Correct for the content-identity
    (set) semantics quod uses for facts; if rule *ordering* ever matters, revisit (M2).
27. **[M2] `quod_ledger_store.erl:197` — `read_range` silently drops a missing index** (a
    gap fails the generator). Add gap detection with the contiguity check (#13).
