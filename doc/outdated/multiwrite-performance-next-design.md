# Multiwrite performance — shared architecture and implementation plan

**DRAFT FOR CLAUDE'S DESIGN REVIEW — 2026-09-15.**
Source base: `7f4500cdd066d7c669976d4d9bec218a3cd9f4fb` (`0.7.200`).
This is a proposal, not an amendment already adopted into the protocol. No
production changes, deployment, new workload or format activation accompany
this document. The pinned prefix of `multiwrite-architecture.md` and Yan's
`write-lanes-plan.md` / `performance-roadmap.md` are not edited.

**Historical status — 2026-09-24.** This review draft records the alternatives
considered from the .200 baseline. It is retained for provenance, but it is not
the current architecture or an implementation authorization. The accepted
contract is `multiwrite-architecture.md`; later implementation and measurement
status is recorded in `performance-roadmap.md` and `WORK-IN-PROGRESS.md`.

## 1. Outcome and scope

Optimize the time until a caller can rely on its writes being applied, and
improve throughput under common multi-ontology workloads. Cover arbitrary
supported target counts, not a special A-to-B transfer implementation.

Atomic L3 and independent L2 already exist. They share an executor; they do
not share outcome semantics. S8 is not reopened as unfinished implementation.
The deliverable is an agreed atomic protocol, the shared implementation with
superseded machinery removed, and a matched atomic/independent measurement.

Primary recommendation for review:

1. Keep the existing applied-before-success guarantee as the default.
2. Investigate one replacement atomic protocol with two parallel durable
   phases, preserving that guarantee. Close the safety/liveness design in §3
   before its implementation, not while patching production.
3. Reuse the installed coordinator, owners, proof evaluator, admission,
   history and certificate implementations. Generalize only genuinely shared
   mechanics. Keep pure lane-specific planning where semantics differ.
4. Examine both lanes before selecting implementation seams. Implement atomic
   changes first, then only demonstrated shared/L2 simplifications, and gate
   both lanes after every shared change.

Reply-at-Decision is a separate product/API decision, not an assumed shortcut
or a prerequisite. Faster acknowledgement must not be reported as faster
application. Targets in the roadmap are measurement gates, not promises.

The .200 correction is deployed: one c4/16 atomic witness committed 16/16,
mean 732.8 ms, median 654.3 ms, p90 966.4 ms, no recovery arms on the eight
observed home voters. Its original block-1504 attribution remains unproven.
The retained report is `/tmp/quod-199-disagreement-G8sYZr/RESULTS.md` with
machine-readable evidence and a final manifest. This is a small post-deploy
witness, not evidence of optimal latency or a complete L2 baseline.

## 2. What exists and what would actually change

### 2.1 Current ordering

For material at source A and target B:

```text
Begin(A) -> Prepare(B) -> Decision(A) -> Finalize(B)
                                                -> exact applied evidence -> client
                                                -> Complete(A), asynchronously
```

Source preparation/application already use the same Prepare/Finalize reducers
inside Begin/Decision. Do not restore separate source Prepare/Finalize blocks
on top of those existing blocks. A protocol replacement may make the source
role symmetric, but must replace the old source controls in that same scope.

The planner is `quod_dtx_recovery:next/2`; `terminal/2` currently waits until
Complete is constructible, including required applied evidence. The coordinator
publishes that terminal event before driving Complete. Thus merely moving an
HTTP reply does not establish earlier certified terminal evidence or recovery.

L2 already uses a source claim, target applications in parallel, verified
per-target results, one complete vector reply, then the source receipt. Its
successful critical path contains the source claim and target application
commits. Target certification must not wait for a slow sibling's unrelated
work or another source block. N=1 uses the same operation model.

Non-conflicting atomic groups already interleave. There is no whole-ontology
single-active-group lock to remove. Consensus block ordering, conflicting
read/write reservations and a queue of independent groups are different costs.

### 2.2 Boundaries that remain fixed

- Default atomicity; independent intent only from the sealed successful proof
  under the settled S6/S8 rules and each target's own authenticated attestation.
- Client request authentication, source binding, exact target/anchor/committee
  identities, local `can_invoke/4` and OCC validation stay real.
- One proof evaluator and temporary-store lifecycle. No KB/Prolog-state copy
  between nodes, second proof, remote request replay, or new interpreter.
- Backtracking retains staged residue; explicit savepoint rollback restores
  its facts/events/effects/provenance; successful intent and mixing rules stay
  unchanged. Keep the `goal/1` action evaluator and `quod_proof_savepoint`.
- Existing fact-before-effect ordering, effect custody, private-effect gates,
  no replayed reactions, no new agent/FIPA executor or outbox.
- Source/target admission generations, signing journal custody, exact-parent
  validation, finality, readiness and committee-change safety remain enforced.
- Same client deadlines and uncertainty grammar. A client timeout or disconnect
  does not revoke an already-durable obligation or authorize new submission.
- .200 recovery installation preserves consumed application acknowledgements;
  verified suffixes do not overwrite same-head owner progress.

## 3. Atomic two-phase candidate — design obligations, not assumed proof

The proposed healthy-path dependency graph is:

```text
sealed, authenticated request and complete participant plan set
                             |
              prepare required roles in parallel
                             |
       exact certified outcome evidence becomes sufficient
                             |
               apply/discard roles in parallel
                             |
       exact applied-result evidence -> existing terminal reply
                             |
             existing durable completion/cleanup lifecycle
```

“Two phases” means two sequential committee-commit waves. It does not mean two
network messages, no certificate exchange, no verification, or a 200 ms bound.
The design aims to avoid a *separate source Decision block* between those
waves. Whether that is safe and simpler is the central review decision.

### 3.1 First wave: bind, reserve and durably choose a local vote

Proposed rule: each required role durably chooses one vote for the exact
operation/manifest/attempt identity, after its existing authenticated-plan,
admission, ACL, OCC and conflict checks. A prepared vote reserves that role's
material. A definitive negative vote is authenticated durable refusal evidence,
not an endpoint's transient `retry`, missing route or timeout.

The source's request-uniqueness/admission role must participate in this first
wave. If it also writes, fuse those responsibilities in its one local record.
If the source does not write, its identity/custody role cannot disappear merely
because writers are elsewhere. Distinguish W material writers, R dependency
roles and O source ownership role; do not claim N writes means N identical roles.

Each prepared record must retain enough bound request/plan/participant data
for existing recovery to discover the whole obligation after driver loss.
Immutable evidence may travel between owners; a mutable KB must not.

**Review must close:** replacing Begin's reference as admission authority,
one accepted manifest per stable signed request, source refusal before or after
other roles reserve, and duplicate/forked manifests arriving at different
targets. The client currently signs the request, not an independently authored
post-proof manifest; “verify the client signature” is not this proof.

### 3.2 Outcome evidence and second wave

Candidate commit evidence: exact positive prepared evidence for every required
role under the same bound manifest. Candidate abort evidence: at least one
irrevocable certified negative vote for that same obligation. The verifier must
prove these cannot both exist under the fault model and membership rules.

After a positive vote, a role cannot release its reservation merely because
its local clock expires. After a negative vote, it cannot later produce a
positive vote for the same identity. The design must specify the journal/index
representation that preserves this exclusivity across owner/node restarts and
committee changes. Existing f+1 outcome attestations do not replace the ledger
consensus certificate needed to order a new prepare or negative vote.

The second phase orders local apply/discard using the exact outcome evidence
and the existing prepared-material reducer. Completion still requires exact
applied evidence before client success. Durable cleanup follows on the existing
owner lifecycle and must remain discoverable after client/driver death.

Do not overload an existing certificate domain to make incompatible statements
look equal. Extend the existing codec/verifier at a justified semantic seam;
keep common quorum arithmetic and signature checking in `quod_quorum`.

### 3.3 Failure and liveness contract Claude must settle

Provide one state/transition table, including all of these schedules:

| Schedule | Required property |
| --- | --- |
| Target reserves before source accepts | Source uniqueness still enforced; source refusal has a durable, verifiable resolution, not a guessed absence |
| Source/client dies before all deliveries | Stored manifest permits the existing recovery owners to complete discovery and delivery without a second supervisor/driver inventory |
| All positive votes exist; one response is lost | Commit remains recoverable; no timeout abort can contradict it |
| One role refuses while another prepares | Every role converges on abort; no prepared material applies and no reservation is stranded after availability returns |
| Message/ack duplicated or response lost | Same semantic identity, no double application, no double effects; transport correlations may differ |
| Conflicting groups reserve in opposite orders | Existing conflict policy prevents permanent circular wait; count abort/retry cost rather than hiding it |
| Temporary unreadiness, then progress | Durable obligation survives, no signing while unready, existing owner event resumes work |
| Membership changes with work prepared | State transfer includes vote/lock/obligation; old-era evidence remains exact and cannot be contradicted by a new committee |
| Mixed history/catch-up/apply-ack ordering | Same reducer and .200 owner-progress merge; no restored blocking marker or lost new wait |

State the liveness assumptions explicitly. A permanently unavailable quorum
cannot be made available by a timer; temporary partitions may leave a prepared
obligation unresolved. Successful recovery after availability returns must be
proved, including when the source is idle and will produce no unrelated block.

Current L2 exact-claim redelivery is already ruled and tested. Current L3
uncertain phase submission has its own discovery/absence discipline. Sharing
the executor does not silently make these policies interchangeable. If the
replacement uses exact redelivery, the contract must bind immutable bytes,
identity and durable target dedup, with its own double-delivery witness.

### 3.4 Alternative dispositions — no automatic fallback ladder

- **Accept the two-phase design:** implement one replacement after its full
  record/authority/recovery contract is closed; remove replaced controls.
- **Reject it with a counterexample:** identify the missing authority. Review
  whether parallel source Begin and participant Prepare with a retained source
  Decision is the sound replacement. That is still three sequential phases
  through application, not the promised two-phase outcome.
- **Earlier acknowledgement:** only as a separately approved public grammar
  distinguishing irrevocably decided, applied, and cleanup complete. Default
  success is not weakened as part of this draft. Record both response and drain
  latency if this option is ever chosen.

Chainspace S-BAC is a reference, not a ready-made one-wave protocol: §IV.C and
Figure 4 include a sequenced acceptance phase after prepared messages. It does
not justify unilateral expiry of a positive vote. See
[the original paper](https://arxiv.org/pdf/1708.03778). No assertion of a format-
preserving change or wipe requirement is made until the actual carriers are
audited in §8.

## 4. Reuse map: existing functions before new abstractions

These names were checked on .200. Internal functions stay internal unless a
real cross-module caller requires an API. Do not create wrapper-only exports.

| Responsibility | Reuse / replacement seam | Boundary |
| --- | --- | --- |
| Proof, sealing and lane selection | `quod_proof_context:seal_plans/0`; Prolog's `finish_pinned_proof`, `submit_sealed_plans`, `route_plans/4` | One seal and lane choice, no new evaluator or payload-only “fast” admission |
| Action/savepoint composition | `quod_proof_savepoint:run/4`; existing temporary-store checkpoints | Rollback and commit intent remain separate; no public savepoint primitive |
| Authenticated material | `quod_dtx:attest_plan/5`, `attested_context/4`, `admission_material/1`, `proposal_readiness/2`; transaction decode/material APIs | Authenticate at each real trust boundary, retain its bound result within that owner; do not repeat full authentication on unchanged readiness turns |
| Atomic planning | `quod_dtx_recovery:next/2`, `terminal/2` | Replace the phase graph here; do not embed a competing planner in Simplex or HTTP |
| Independent planning | `quod_operation:new/4`, `work/1`, `accept/5`, `restore_receipt/2`, `completion/1`, `results/1` | Keep N=1/N-target model; independent targets continue independently until the final vector join |
| Execution, cancellation and result correlation | Coordinator `drive/1`, `start_typed_wave/4`, `advance_wave/1`, `resume_target_continuations/1`, `finish_typed_wave/5`, `request_progress_drive/1` | One loop and one wave lifecycle; ordered work is a one-item wave, no alternate blocking receive loop |
| Durable custody and admission | `quod_dtx_owner:admission/3`, `classify/2`, `desired/3`, `reconcile_journal/4`; Simplex journal/reconciliation | Existing sole signer/ledger owner; no second pending inventory; indexed inclusion before readiness |
| Phase transition and publication | `quod_dtx:preview_batch/3`, `reduce/4`, `reduce_batch/3`, `acknowledge_finalize/4`, `install_projection/3`; Simplex sink/appliers | Reuse prepared-material application; append/install before publication, preserve acknowledged progress |
| Canonical independent claim/result | `quod_transaction:remote_claim/5`, `remote_application_material/3`, `remote_complete/4`; `quod_operation_vector` | One authenticated materialization, canonical complete target vector, no alternative receipt walk |
| Exact evidence | `quod_foreign_log:resolve_reference/6`, `verify_local_deadline/4`; Simplex `dtx_local_evidence/4` | Expected-target first; hosted reads stay hosted; one sufficient pinned capture; no request-time prefix replay |
| Indexed history | `quod_dtx_phase_index:capture/2`, `preview_batch/4`, `commit_delta/2` | One writer, read-only captures, changed-window work only; no network wait holding mutable custody |
| Applied/read certificates | `quod_dtx_current_view:certify_applied_many/3`, `certify_operation_evidence/6`, `certify_reads/3`; `quod_applied_certificate`, `quod_read_certificate`, `quod_quorum` | Reuse collector mechanics and one quorum implementation; preserve domain and evidence distinctions |
| Transport | `quod_dtx_endpoint` framing/correlation; Simplex `dtx_endpoint_request/7`, `dtx_endpoint_local/4`; coordinator delivery waves | Per-peer transport IDs, stable semantic record; first valid response does not cancel durable work |
| Discovery/progress | `quod_reg`, existing local progress and `quod_foreign_log:follow_request/1` / `unfollow_request/1` | Existing gproc names, monitors and feeds; route/status notices grant no verdict authority |
| Tracing | `quod_trace`, `quod_attempt_span`, existing stage/wave/owner spans and O analyzers | Diagnostic failures never change results, deadlines, signing or shutdown |

The common executor must not become a generic workflow framework. Different
certificate statements and different lane planners are meaningful distinctions,
not duplicate code to erase with an untyped dispatch table.

## 5. Process and message design

No new long-lived Erlang process, registry, database or scheduler is proposed.

| Existing owner | Owns | Resumes from / ends on |
| --- | --- | --- |
| Namespace Simplex | Ledger, signing journal, installed protocol/index state, coordinator lifetime | Existing consensus, applied acknowledgements, readiness/admission and monitored child messages |
| Namespace Prolog and proof sessions | Local KB publication, proof temporary stores, caller reply | Existing ordered apply channel and correlated result; proof cancellation does not cancel durable writes |
| Monitored coordinator | Disposable verified observations, pending action correlations, subscriptions | Local owner progress, foreign follow, worker/result/DOWN, gproc owner changes; owner death ends it |
| Existing wave/verifier workers | Bounded I/O/crypto under one action deadline | Exact replies or genuine terminal failure; cancellation reaps resources, not durable obligations |
| Foreign-history owner and existing writer | Non-hosted verified prefixes and queued acquisitions | Identity-bound feed/directory/history changes; one writer per identity |
| Existing transport and effect owners | Link resources / durable effect custody respectively | Their established messages and journal lifecycle; no new outbox or effect executor |

Use `quod_reg`'s existing gproc naming/pub-sub conventions and exact owner PID /
incarnation correlations. gproc notification is a wake, not evidence. Do not
assume order across two recipients or that a send trace means mailbox delivery.

For every wait, name: predicate, owning process, progress event, subscription
installation, race-closing recheck, original deadline and cancellation. Reuse
the owner's serialized check/register operation where it exists. Otherwise
subscribe then recheck through that owner; a lost-wakeup fix must not introduce
a second queue. An edge arriving during worker I/O is retained in the existing
wave and consumed when its result is installed.

Forbidden healthy-path mechanisms: polling, sleep/backoff ladders, waiting for
an unrelated next block, periodic status probes, readiness-driven coordinator
replacement, network/crypto inside an owner callback, or a fresh timeout per
delivery peer. Terminal deadlines, the consensus pacemaker and real failure
detection are not polling and must not be indiscriminately deleted.

Caller deadline, admitted-action deadline and durable obligation lifetime are
distinct. No deadline extension to turn a failure green; no client timeout
converted to abort; queued results are checked against the original deadline.

## 6. Performance and deletion obligations

### Structural work bounds

- Hosted sufficient evidence: no routed job or old-prefix verification.
- Unchanged blocked intent/readiness turn: no repeated whole-plan authentication,
  signing, candidate construction, or trace-driven work.
- Reserve/apply once per exact role identity; later exact delivery uses existing
  inclusion/dedup, without repeating signing or facts/effects.
- Build an eligible batch once using the authenticated owner view. Preserve
  FIFO, conflict and slot eligibility checks; no early signing or admission.
- Keep each target's continuation independent; only protocol-required joins
  block the next phase. No new all-sibling join for L2 certification.
- Count encoding, signature verification, disk reads, workers, allocations and
  bytes, not just wall time. Audit repeated decoding using actual callers and
  trust boundaries before removing it.
- A certificate set of size N sent to N targets can cost O(N²) aggregate bytes
  or verification. Report it; do not promise flat total work or introduce a
  second certificate authority to conceal it. Separate fixed-per-target work
  from fixed-total-work experiments.

### Deletion ledger, maintained inside each implementation scope

For each affected responsibility record: old functions/callers, replacement,
proof/control, deleted lines, added lines and surviving reasoned branches.

If the reviewed protocol replaces Begin/Decision semantics, remove their
superseded constructors, planner arms, reference dependencies, validators,
signing/admission branches, journal/index rows, recovery walks, endpoint fields,
trace names, fixtures and comments together. Preserve any retained terminal
receipt responsibility explicitly; deleting a record name is not deleting its
durable recovery obligation. Do not delete the underlying common reducers.

For shared cleanup, remove proven duplicate walks/validators/materializations
and production exports used only by tests. Keep verification at independent
trust boundaries. xref/Dialyzer are supporting evidence, not proof of deadness;
missing trace coverage is not proof that failure/restart code is unused.

Inventory stale comments directly. Example on .200: the coordinator moduledoc
describes only the group planner despite operation/dormant entry points. Update
that description with its affected scope. L2 slice-6/7 and operation-lifecycle
documents already have historical/superseded headers: do not repeatedly rewrite
them or remove their evidence. Update current architecture outside its pinned
prefix; keep commit diaries and controls in the handoff. Submit amendment notes
for Yan's protected plans rather than editing them.

Required accounting: net production lines across the replacement scope and
combined stack, functions/branches/processes removed, and tests/docs separately.
Aim for a smaller production implementation. Do not minify, move code off the
counted path, remove safety checks, or call file splitting a reduction. If a
safe design cannot meet the requested reduction, disclose that at design review.

## 7. Sequence and gates

| Stage | Deliverable and exit | Publication rule |
| --- | --- | --- |
| D — this review | Claude rules on §3, client boundary, reuse/deletion map and measurement plan; counterexamples resolved in one consolidated contract | Documentation only; no implementation authorized by an unresolved candidate |
| P — executable design and baseline | Deterministic state-machine schedules prove vote exclusivity, authority, recovery and complexity bounds; migration inventory; bounded missing .200 L2 baseline | No production protocol change; freeze model, sources, counters and full logs |
| I1 — coherent atomic replacement | New canonical records/planner/reducers/recovery/endpoints together, old replaced protocol deleted, real production controls and full gates | One protocol scope/commit plus label; no permanently selectable old/new engines |
| I2 — shared/L2 refinement, only where demonstrated | Reuse target continuation/certificate/admission mechanisms, remove actual duplicates; preserve both guarantees and N=1 | Separate behavior-preserving scope if independently complete; fold inseparable changes into I1, not an adapter branch |
| H — hardware acceptance | Exact deployed image, retention/format plan, matched atomic+independent matrix, complete timing attribution and resource counts | Review before release under standing rules; authorized rollout only after contract/safety gates, no repeated unchanged campaign |
| C — close | One current architecture, deletion ledger, open residuals and reproducible before/after results | No “complete” claim based on compilation or earlier reply alone |

P must produce a counterexample or a closed design, not become an unlimited
measurement exercise. If §3 cannot be closed, hand off the exact unresolved
authority/liveness question and continue only separable shared/L2 work. Do not
silently switch to A/B/C in succession or ask Claude to approve cosmetic
intermediate states. Exact-tree review covers a coherent responsibility.

### Required permanent tests and fail-before controls

| ID | Control/oracle |
| --- | --- |
| T1 | Independent gate holds source preparation; other first-wave targets are dispatched/accepted without a committed Begin. Baseline fails the removed dependency, not a stub timeout. |
| T2 | One signed request presented with two manifests: existing source authority permits at most one accepted obligation; targets cannot commit the fork. |
| T3 | Commit and abort evidence cannot both validate for one identity, including duplicated/reordered votes and stale committees. |
| T4 | Prepared role + delayed certificates + expired caller: no unilateral unlock, no late contradictory vote; post-restart recovery resolves safely. |
| T5 | Durable negative vote before/after other prepares: abort reaches every holder, zero applied facts/effects, locks eventually released under restored availability. |
| T6 | Kill driver/source/target at each durable boundary; same request recovers via existing owners, no new semantic submission, exactly one application/effect. |
| T7 | Source is/is not a writer; 0/1/2/4/8 writers; extra read-only dependency; alias/co-hosted/different-anchor targets. Correct lane/role set, no N=1 executor fork. |
| T8 | Conflicting transfers, opposite reservation orders, disjoint groups and stale OCC reads. Conservation and progress hold; no double-spend or unnecessary global serialization. |
| T9 | Withhold final target apply/AM3 evidence: default client success remains pending; after actual application it returns once, without an unrelated source block. |
| T10 | L2 one target rejects, another commits, another pauses: completed targets are not reapplied; one complete certified vector, no partial final reply or atomic fallback. |
| T11 | Progress before/during/after registration and worker return, duplicate/unrelated notices, owner replacement, caller deadline. No lost wake, false authority, busy loop or deadline reset. |
| T12 | Real endpoint fan-out: unique per-peer request IDs, identical semantic bytes; losing transport cancellation never cancels durable work. |
| T13 | Same-head apply ack during recovery, new suffix wait, completed-marker removal; retain .200 and C-scope install/application ordering controls. |
| T14 | SDK disappearance, sampler/drop/tie cases, unwind and callback death. Result/error/shutdown unchanged; owner-span accounting stays honest. |
| T15 | Backtracking, cuts/findall, ordinary failed-branch residue, mixing, nested intent, action savepoints, retained events/effects, unsigned and own-seal refusal. Existing proof semantics unchanged. |
| T16 | Count-based repeated-blocked-turn and target-scaling controls: no prefix work, redundant authentication, unintended serial sibling barriers, duplicate materialization or hidden second worker engine. |
| T17 | Real old carrier bytes rejected by name if formats change; empty fresh stores found correctly; applied/receipt/request references retain correct era binding. |

Reuse existing `quod_dtx_recovery_tests`, `quod_dtx_coordinator_tests`,
`quod_dtx_owner_tests`, `quod_dtx_inclusion_tests`, operation claim/recovery/
receipt/vector tests, certificate/quorum tests and real-node ask/consensus CTs.
Do not replace production-path controls with stubs. Test barriers establish
actual receive/owner-state ordering, not send-trace ordering or sleeps. Keep
all failed gates and control logs with true exits and exact variant hashes.

For each implementation scope: fresh isolated `_build/test`, full sequential
unsandboxed 17-command current gate sequence, including eight CT suites, xref,
Dialyzer, both releases, UI build/lint, staged and unstaged diff checks. Stage
new files in the review candidate so diff checks include them. Freeze exact
source/dependency/patch inputs. A combined-suite flake invokes the standing
triage protocol before the run is trusted; no silent repeat-to-green.

## 8. Formats, deployment and historical evidence

Parallel preparation cannot reference a future committed Begin slot. Therefore
even a design retaining a source Decision may change canonical record fields
or validation rules. Audit bytes before asserting “no wipe” or “must wipe”.

Audit at least: transaction envelope/semantic IDs, DTX control/manifest tags,
endpoint vocabulary, local and foreign ledger segments, signing journal,
effect-journal stored submissions, foreign identity/checkpoint metadata,
outcome index and DTX phase-index certificate carriers. Several live inside
`quod_foreign_log`/existing owners, not separate new store modules. Start with
the S7 inventory, but read current .200 implementations (foreign cache is v4,
not the historical S7 v3). Name every additional embedded carrier found.

If bytes or historical validity break: one deliberate coordinated format cut,
old formats refused by name, no dual decoder/protocol mode. Present the exact
affected volumes and preserved identity paths for deployment authorization.
This draft performs or authorizes no wipe. Archive the retained reproduction
and both-lane baseline first. A re-found means a newly labeled baseline;
neither .200 latency nor history-dependent gains are directly comparable across
the wipe. Compare matched old/new code on equivalent fresh diagnostic state
if a causal protocol comparison is required. Never rewrite certified history.

If format-preserving: coordinated fleet swap when validation/wire rules require
it, with exact before/after namespace/anchor/committee/identity retention checks.
Stop once, use the guarded job submission, record actual image and config diffs,
verify health/logs, and preserve any failed startup snapshot honestly.

## 9. Measurement contract

Use existing campaign harness/admission, independent start denominator, native
owner capture and O analyzers. First reuse .200 evidence; collect only missing
comparison cells on a fresh label. Never restart old campaigns or clear STOP /
BENCH_STOP. Stop issuing work on the first failing measured request, retain
already in-flight work and resolve read-only; no uncertain-write resubmission.

Primary before/after sentinel: atomic and independent two-writer c4, 16 requests
per lane, same per-worker shapes and placement. Then the acceptance matrix:

| Dimension | Required cells |
| --- | --- |
| Lane | Atomic L3 and independent L2; N=1 one-hop/shared-path control |
| Material writer count | 2, 4, 8; count readers/source ownership separately |
| Client concurrency | c1 and c4 for each writer count; c8 at 8 writers as a separate stress cell |
| Placement | Matched primary placement; source-included, source-not-writer and co-hosted layouts as separately labeled controls |
| Work | Disjoint per-worker conserved atomic transfers / exact independent per-target changes; intentional conflicts separately, not blended into latency |
| Run size | Predeclare 16 requests per cell; first-wave and later requests reported separately. Freeze any repeat plan before its results, no repeated runs until a desired number appears |

Keep committee size independent of writer count. Report physical sharing and
committee overlap: eight ontologies on overlapping voters is not eight
independent sets of hardware. Warm every contacted node using the established
bounded recipe; warm-ups have their own ledger effects/labels. Cold-start and
connection startup costs remain separate measurements, not silently excluded
failures. Do not compare a striped fifth request with the concurrent-four cohort.

For every request retain: signed identity, lane/targets, submitter start/end,
proof/seal, owner admission, proposal/eligibility, certified prepare/outcome,
apply/AM3 evidence, reply and cleanup times. Reconstruct a dependency graph;
do not add overlapping child spans or subtract percentiles. Same-VM monotonic
durations first; cross-host ordering needs correlated certificates/slots and
explicit clock uncertainty. Admission-to-dispatch is not mailbox residence
unless receipt and dispatch boundaries actually bracket it.

Report latency distributions plus means, throughput, phase commit counts,
queue/residence bounds, recovery arms and non-voting intervals per observed
node, signatures/encodes, history opens/replayed entries, worker counts,
reductions/GC and network bytes. Counters belong at existing owner/work seams;
reuse existing measurements before adding instrumentation. Any new spans are
bounded and SDK-loss safe, not a second production observation state machine.

O-A1/O-A2: keep all attempt starts and excluded coordinators in the denominator;
list missing/tied/dropped-event roots by identity and reason. Reconcile the
effective sampler and sampled/recording flags. A reviewed `always_on` diagnostic
window is configuration-only, bounded and reverted with exact config diffs;
ordinary sampling stays explicit otherwise. Zero pins mean unobserved, not zero
work. Existing .200 cloud directory warnings remain named open items.

Acceptance: all correctness/state oracles pass, structural phase/work reductions
are demonstrated, and end-to-end applied latency improves in matched cells
without shared-lane failure/throughput regressions. Quantify variation and
limitations; a 16-request result does not establish a tail guarantee. The
200–300 ms atomic aspiration is not “passed” by a faster acknowledgement or
by extrapolating old phase means. If the gain fails to appear, inspect the
recorded critical path and disclose the result before any further scope.

## 10. Decisions requested from Claude

Return one review of this complete design direction, with source-backed
corrections and explicit counterexamples where necessary:

1. **R-SEMANTICS:** preserve applied-before-success by default; any decided-only
   API is separate. Confirm the three lifecycle boundaries.
2. **R-PROTOCOL:** can §3's two-phase certificate/role design safely replace the
   separate Begin/Decision dependencies? Close request uniqueness, vote
   exclusivity, safe refusal, conflict progress, ownership after crash and
   committee change. State any blocker; do not approve a diagram alone.
3. **R-REUSE:** approve/adjust the exact reuse map and one-executor message
   lifecycle; identify real mandatory new representation, not speculative APIs.
4. **R-FORMAT:** specify the canonical records and carrier impact before coding;
   no unsupported byte-preservation or wipe claim.
5. **R-REMOVAL:** name replaced code/records/comments and retained responsibilities;
   approve the scope boundaries and honest production-line reduction criterion.
6. **R-MEASURE:** approve the bounded matrix, all-request denominators and matched
   baseline rules. Identify missing controls now, not after each tiny patch.

Once settled, fold the approved contract into the current architecture outside
its pinned prefix, with one status source and explicit supersession links.
Do not modify Yan's two plan documents; report their required amendments.
Keep unrelated open scopes (R-RESTART-RACE-01, fast restart/F6, agents/FIPA,
Scope B, unresolved EUnit/CT flakes and cloud warning cleanup) out of this
performance replacement unless a concrete dependency is demonstrated.
