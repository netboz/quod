# Simplex occupied-turn diagnosis

Status: diagnostic implementation and independent consensus review complete;
**approved for commit and preserved-ledger diagnostic deployment**. Both gate
runs passed EUnit 1885/0, ask/QUIC CT 26/26, Simplex CT 12/12, xref,
dialyzer and diff-check. No new hardware result is claimed. This is the next local instrument requested by the independently
approved [0.7.156 hardware review](consensus-tracing-hardware-results.md).
It does not change consensus or establish a new performance result. Consensus
review-before-commit remains in force.

## Evidence and question

The preserved-ledger 0.7.156 capture committed 400/400 writes. Its one-hop
p50/p99 remain **371/422 ms serial and 857/1167 ms c4**, failing the 300 ms
serial-median and 450 ms c4-tail gates. Keep these two findings separate and
visible: serial `operation_result` rose **161.396 → 191.334 ms (+18.4%)**;
the paired source target-call exceeds target endpoint duration by **137.462 ms
mean at c4**, still without exclusive attribution. This local diagnostic is
not a promise to explain that entire cross-owner/transport interval.

Two same-owner cases motivate this cut:

| Case | Established interval | Still unknown |
|---|---|---|
| Source slot 786 | 288.780 ms after durable local support until notarization, with a short valid parent check | Owner occupancy, queued-share observation, scheduling, or remote/transport delay |
| Request 44 | 112.582 ms from result notification to source-owner acceptance, overlapping slot-793 receipt work | Which synchronous callback/substep occupied the owner, if any |

Raw evidence: `/tmp/quod-consensus-156-YfnvgZ/benchmark/diagnostic-timeline.json`,
`independent-slot-diagnosis.json` alongside it, and
`/tmp/quod-result-analysis-156-B7HZWN/REPORT.md`. The evidence archive hash and
individual trace IDs remain in the hardware report. The original 1,625 ms
mixed-block outlier did not recur; its absence is not a fix. There were 59
repeated physical receipt rows in the new window, not zero, with no duplicated
applications and no mixed claim/receipt block in that window.

The late share observation is **not** a timestamp at the network ingress or
mailbox enqueue. Several short owner callbacks during the wait do not prove a
remote-late share: that share may already be queued behind them. Even an empty
mailbox observation must be distinguished from OTP's internal event queue,
process signal delivery and time when the process was not scheduled.

## One existing execution and tracing path

`quod_simplex:running/3` is the sole `gen_statem` state callback. Its existing
wrapper covers `running_impl/3`: authentication/decode, dispatch, synchronous
validation and `keep_progress`. Instrument that boundary and its existing
`timed_step/3` calls. Do not add an executor, monitoring process, callback mode,
message, timer, queue, or wire field. Do not alter callback results, returned
OTP actions, verdicts, quorum thresholds, deadlines or replay behavior.

The existing `quod_trace` helper owns the instrumentation:

- Each callback produces an independent `quod.consensus.owner_turn` root.
  Autonomous receipts and callbacks without a sampled client parent are covered;
  unrelated work is not falsely parented under whichever client is waiting.
- Attributes contain namespace, local slot/approved frontier at entry, a closed
  event class, PID, a random process-incarnation token and monotonic turn sequence.
  They contain no raw event, principal, key, goal, state dump or exception term.
- Entry/exit observations record monotonic nanoseconds, mailbox lengths and
  the reduction delta. The observed window includes start-span instrumentation
  overhead. Wall duration includes descheduling; reductions are **not CPU time**.
  The entry/exit snapshots are observations, not an atomic mailbox monitor.
  Use their explicit monotonic interval for occupancy: raw SDK span timestamps
  exclude some prologue and include the diagnostic epilogue, whereas the exit
  observation precedes attribute export. Reductions include instrumentation.
- Existing named synchronous substeps become `quod.consensus.owner_step` children
  (engine, persistence, feed, resolution, support, ingress/custody draining,
  recovery, readiness, broadcast, and head reconciliation). Nested substeps
  nest under the actual active step. Their interval union, not their overlapping
  sum, is used to subtract from a turn. Uncovered time stays explicitly named.
- Active diagnostic context is process-local and restored with `try…after`.
  It is **never attached as the SDK ambient request context**: existing request
  trace parenting and asynchronous context propagation remain unchanged.
  Root/step spans end on return, error, throw or exit without inspecting the
  returned value or failure payload. Untrappable process death can leave an
  unexported turn; absence cannot be called idle.
- The incarnation/sequence pair is constant-space local diagnostic metadata,
  not protocol state or retained history. A sequence advances even when its
  root is unsampled, so missing interior turns are detectable. A first/last
  missing span requires capture-boundary evidence, not just adjacent sequences.

`node.consensus_owner_tracing` is a new **default-false node-local diagnostic
setting**, rendered by the existing Nomad config. The application config owner
sets it and Simplex reads it once at process initialization. Dynamic/recovered
ontologies therefore obey the same node policy. It is not placed in a prepared
lifecycle config, journal, hosting fact or canonical bytes. The existing
`detailed_consensus_metrics` remains independently false: enabling this capture
does not turn on synchronous per-event Prometheus probes.

## Capture and interpretation gate

After consensus review only, deploy with preserved ledgers. Use the existing
OTLP exporter and complete sampling for a short source-owner capture, and
explicitly verify the switch on the dynamic source (not merely root). Owner
roots are separate traces: retrieve them by namespace, service instance,
incarnation and capture window, not only by benchmark client trace IDs. Run
ordinary requests overlapping autonomous receipts; never resubmit an uncertain
write to manufacture a reproduction.

Archive driver output, all requests, raw owner roots and children, exporter
drop/error counters and configuration. Require consecutive sequences between
bracketing turns on the same owner incarnation and complete child export before
making an absence or exclusive-substep claim. Sampling/export loss, owner death,
missing boundary spans or incomplete child retrieval invalidate that claim.
The diagnostic creates substantial additional span volume; its overhead is part
of the capture, and no faster/slower latency result is attributed to a protocol
change. Compare an instrument-off control before using absolute numbers.

For each suspect source-local interval, partition callback overlap, gaps and
the callback's nested substep union using one clock. A long callback localizes
occupancy, not necessarily CPU (it could be blocked or descheduled). Gaps include
OTP action processing, internal event dispatch, process scheduling and idle
time; this instrument cannot distinguish all of those. A draining owner alone
does not prove a remotely late share. Preserve a residual/unknown bucket.

Only if evidence rules out the local boundary should a proposal-context
extension be designed and reviewed on the authenticated relay surface. No such
extension is in this cut. The duplicate-receipt verification contract, result
authentication, Q4, finality, L2 and compaction keep their separate gates.

## Tests and review

Tests use the real SDK and production callback, not a second dispatcher. Pin
exact callback results/actions and exception behavior; whole message-controlled
callback occupancy; nested step hierarchy and cleanup; unchanged ambient context
under sampled/unsampled clients; autonomous turns; sequential root isolation;
mailbox observations/reductions; sequence gaps under dropped sampling; and no raw
sentinel payload in exported metadata. Pin node-local config propagation without
writing diagnostics into prepared lifecycle state.

Run focused tests, then clean-build sequential EUnit, ask CT, QUIC CT, Simplex CT,
xref, dialyzer and diff-check. Report actual gate counts and all development
failures. Do not commit or deploy until the independent consensus review closes.
Yan's write-lanes document and SVG edits remain excluded.

Local results (2026-09-09): focused **47/0**; clean-build sequential, unsandboxed
**EUnit 1885/0**, ask CT **26/26**, QUIC CT **26/26**, Simplex CT **12/12**,
xref and dialyzer exit 0, diff-check clean. Logs are under
`/tmp/quod-owner-turn-review-f8EuOe/`; focused log is
`/tmp/quod-owner-trace.C6Zxam.log`. The focused development run first exposed
five test-macro variable-capture failures in nested EUnit assertions, corrected
in the tests without changing production behavior or weakening assertions.
Only explanatory Simplex comments changed during the full gate sequence;
no executable source changed. The new callback/control/config tests account
for all 18 additional EUnit cases over the 0.7.156 diagnostic baseline.

Wiring negative control also passed: the unmodified live-callback test succeeds;
replacing only `running/3` in an isolated VM with delegation directly to
`running_measured/3` fails precisely at `take_owner_turn/1` with
`{missing_owner_turn, Ns}`. Source, tests and original BEAM remain hash-identical.
Script and `control-positive.log` / `control-negative.log` are in the gate
directory above. This is an in-memory mutation, not a test-specific production
branch or a restored polling path.
