# C4 Phase 1 — rare starts, effective sampling, ordinary spans

Yan's descope is controlling. Phase 2 is shelved unchanged in
`/tmp/quod-c4-observation-impl-Oc5Pqx/review-question-freeze-v2`.
Its hot callback hooks, event counters, wait/dispatch capture and SDK decorators
do not ship. The capture-cut question is closed, not solved: no owner pause,
acknowledgement, extra turn or shutdown change may buy exact capture equality.
If revived later, cut uncertainty needs named exclusions and controls.

## Shipped scope and removal

Only `quod_trace:start_span/4` gets an opt-in call site, restricted to the rare
`quod.dtx.coordinate` allocation. Ordinary builds erase it. Build the diagnostic
release with `rebar3 as c4_phase1,prod release`; no application configuration
enables it accidentally. The coordinator, Prolog, Simplex, foreign-log, durable
formats, endpoint vocabulary and deploy template are byte-identical to the
published .163 base. This branch contains no slice-7 code.

The allocation operation delegates exactly once to the same SDK tracer, with
unchanged context/options/result/exception. Only closed metadata is projected:
exact parent/child identity, sampled/recording/remote flags, effective sampler
branches and exact stored ratio threshold. No event payload, arbitrary SDK
configuration, process state or key enters the external record. A missing or
failed allocation record is unknown, not a missing attempt or an export verdict.
The read-only SDK snapshot records exact cached application/default samplers
and the two whitelisted sampler environment requests, before/after capture.

The external collector preserves the prior rare-start VM call-counter regime
at `start_dtx_coordinator_worker/7`, including tentative/failed starts. Pinned
owners, native/received/assigned counts, exact-PID delivery barriers and cleanup
remain required. Only those PIDs are traced, with arity and timestamps; no
descendants, mailbox polling instrumentation or callback counters are added.
The pre-existing external observer's bounded lifetime/storage/health/teardown
machinery is reused, not moved into production owners. Allocation metadata has
no second counter. Missing/duplicate/unmatched metadata never shrinks the start
denominator or silently becomes sampling evidence. A start in the rare shutdown
gap still fails the strict native denominator check conservatively.

Removal: omit `c4_phase1` to erase the hook, remove this scope's new files and
the small include/profile/call-site edits. No state or durable cleanup required.

## Configuration-only 100%-sampling window — not executed

`scripts/c4/sampling-window.mjs` produces a pure plan from the exact existing
template: its two `OTEL_TRACES_SAMPLER=parentbased_traceidratio` values become
`always_on`. No other template byte changes. The pinned SDK ignores the ratio
argument for `always_on`; its unchanged value remains 0.05. The plan records
both hashes and line diffs, and the inverse
restores exact original bytes only if the current window configuration still
matches. Drift refuses overwrite. The repository template remains at 0.05.

Parent-based root ratio 1.0 would **not** override an unsampled parent, which
is why the window selects `always_on` instead. Real-SDK tests pin both cases.
Verify effective cached samplers and every attempt's flags; configuration alone
does not prove allocation or export. This window
is observer-on/always-on-sampling diagnostic data, not a normal-sampler latency
baseline. The old 17 missing roots cannot be retrospectively classified by it.

## Explicit deployment/witness sequence — awaiting review and deploy go

1. Claude's exact-tree review, separate source commit and patch bump; only then
   Yan's explicit coordinated fleet-swap go. No wipe or slice-7 bytes.
2. Freeze the existing job/template/check index, identities and retained-ledger
   snapshot. Preserve all 40 namespace rows, anchors and committees; verify the
   planned image/config-only inverse diff before one guarded submission.
3. Record effective sampler snapshots on each allocation. Arm the reviewed
   external rare-start collector on the exact existing campaign source cohort;
   capture every replica/replacement start, not only the submitting replica.
4. Run **one** freshly labeled five-request c4 witness with the existing ABCR162
   shape, absolute client bound and stop-on-first-failure. Honor STOP and
   BENCH_STOP; never clear old markers or reuse a failed label. Do not resubmit
   an uncertain signed operation. Preserve full outputs and true child exits.
5. Stop/read/release the observer, retain incomplete captures as incomplete,
   retrieve ordinary spans by the captured exact trace IDs as well as the
   original client traces, retain failed retrievals, and compare retained
   ledgers after the swap/window. Owner death invalidates the witness.
6. Restore the exact original sampler configuration after the bounded window,
   with check-index/inverse checks and before/after retention comparison. A
   failed run still requires restoration, but uncertain job writes require
   readback, not blind submission. Do not launch a second witness automatically.

These are reviewable instructions, not deployment authority or executed work.

## Reports and exclusions

`scripts/c4/analyze-phase1.mjs OUTPUT CAPTURES_JSON FULL_TRACE_JSON ...` consumes
the original native captures (array) and full OTLP documents and writes a fresh
report exclusively. The same frozen client results and independent group
inventory can also feed the reviewed `scripts/c4/o/analyze-campaign-O.mjs` CLI.
All 13 imported O source/test files are exact reviewed hashes; baseline files
are not rewritten. Capture VM scope includes the window token plus exact
allocation/owner pins; node-name strings alone never bind a VM incarnation.

The report retains each independent start, allocation uncertainty and missing
root. Sampling gives explicit lower/upper numerator counts over the original
missing-root denominator; sampled-but-missing roots are not blamed on a 5%
root policy. Root identity reuse and parent-class contradictions remain unknown.
O-A1/O-A2 apply: excluded attempts and coordinators are counted/keyed/reasoned,
timestamp ties are ambiguous, stored event drops exclude intervals, and no
denominator shrinks. Unsafe timestamps are refused before precision is lost.

Post-start timelines use **ordinary** coordinator events and descendant spans,
ordered by exact timestamps rather than SDK wire position. They distinguish
L3-only wave work, shared history/quorum work, and unresolved generic spans.
Cross-allocation clocks, dropped metadata, missing exits and unobserved work
remain explicit; parallel durations are not summed or relabeled as CPU time or
exclusive mailbox attribution. Queue-wait-before-start was refuted by ABCR162;
Phase 1 must not revive it by inference. Missing coverage is not idleness.

Full clean sequential gates, diagnostic SDK/owner controls and exact-tree review
are required before commit. c4, +8.7%, R-RESTART-RACE-01 and both EUnit items
remain open. No latency/performance or hardware-acceptance result is claimed here.
