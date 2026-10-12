# Generic hinged views — partial acceptance

Tracker: [QUD.36](nimbalyst://QUD.36), stable id
`task_1791635398662_3io1m7`. The shared implementation prerequisite is
commit `05f8b42bfd554115f77b32b660707dcdcbbd1a68`.

The integration is committed and all eleven release gates passed. Candidate
0.7.264 is deployed on the retained eight volumes. Live personal-world blocked
close and simulator recovery passed; full acceptance remains unfinished. Work
stopped expanding at Yan’s credit-cost request. No runtime reuse fix or further
release was started. See the live findings below.

## Implemented and verified

[hinged_example_view.pl](../../../priv/ontologies/hinged_example_view.pl) is an
optional authored Prolog recipe. It gives each moving body one body-bound
group, retains local appearance attachments and displays the committed reusable
hinge state. Both existing example definitions supply their appearance data.
No Erlang, Rust or client branch was added.

The new production-owner test uses the ordinary signed simulation WebSocket
and signed action ingress in two independently anchored ontologies. The door
and compound lid have different axes, travel directions and targets; the lid
retains its nonzero 400 mrad target and handle attachment. For each it verifies:

- Viewing does not authorize closing. A denied signed request leaves it idle.
- An authorized close moves the native body and commits `blocked(12)` with a
  checkpoint. Its ordinary view displays “Blocked”.
- Simulator replacement restores the blocked pose from that checkpoint.
- A governed obstacle move permits a new close to commit `closed` at the
  authored target. The ordinary view displays “Closed”.
- Another simulator replacement restores the closed pose, while the authored
  completion consequence remains recorded exactly once.
- The other world's height stays unchanged during recovery.

Recovery position tolerance is 2 mm; quaternion agreement accounts for the
checkpoint's mrad rounding. This is a local signed production-seam test, not
the real personal-world browser acceptance.

[owners-01](owners-01/result.json) passed **208 physics and lobby tests**, with
zero failures and a true child exit of zero. This includes the existing
cancel/replacement, stale/duplicate evidence, competing edits, original-operation
resolution, body lifecycle, authority/actor recovery, atomic receiver and strict
unchanged-work obligations from the shared repair. Counts overlap with earlier
repair evidence; they are a new run on this scope. The focused final view run is
[signed-view-06](signed-view-06/result.json).

[client-03](client-03/details/result.json) passed **134 client cases** across
15 separately executed test files; every actual child exited zero. Earlier
Node 26 runner output reported only file-level aggregates and is retained
without claiming an internal case count. The owned baseline browser closed
with [exit zero](signed-personal-baseline/browser-exit.json); its private
profile remains outside the evidence.

The authored production delta is **+30/-0** lines in the optional Prolog recipe;
test definitions and coverage are **+135/-2**. The growth provides authored
appearance composition and signed-view acceptance, with no additional process
or mutable state owner. The pre-existing user changes are excluded.

## Personal-world baseline before live changes

[Signed reads](signed-personal-baseline/baseline-physical.json) and
[the ordinary scene](signed-personal-baseline/baseline-scene02.json) retain the
existing acting namespace
`human:5pU3X8evhfH09g1ctl0LRRP80zmhd6M7g8OQ7DyOeaE`, instance `me`, anchor
`758F8AA13D54CF626BA493A6BFBEC24548AC96B49DD0FEDA3BC0843E0838CBF2`.
The world is that namespace plus `/lobby`, instance `personal_lobby`,
anchor `7082C150269E5B82754C06CB7928F6E55FFBCEDABD25E642C2CCF874A3A6F77F`.
Baseline human/world heights were 358/188. The four existing bodies, floor opening,
console, roof, six authored marks and attachments are retained; joints and
checkpoints are empty. The existing profile opened the normal browser view
and reported “Physical space ready”. No private key was exported.

[Eight-node inspection](preflight-02/scope-inventory.json) found two active
physical scopes: the actual personal world and the earlier generic gallery.
Neither has old door/rest activity, joints or checkpoints. Before this campaign the candidate was
0.7.263 at job version 71 / modify index 847862; all eight allocations have
zero restarts. The main job and ingress are unchanged.

## Governed source installation

Package changes cannot rewrite the retained old ontology rules. Comparing the
old core library, the new core/hinged/view libraries and the actual current
source yields [55 predicate edits](source-preparation/replacement-drafts-02.json),
with [zero baseline conflicts](source-preparation/replacement-conflicts-02.json).
Other authored clauses, including agent-instance defaults, are preserved.

A fully expanded explicit edit exceeds the current signed parser/encoding
allowances. Ordinary composition of the existing source compiler and guarded
edits produces a compact signed request within those allowances. A small
production-owner probe commits and reads back correctly, including when its
temporary bindings are contained by `findall/3`.

The complete atomic replacement then fails through the real owners. Bounded,
redacted tracing at the existing result-normalization boundary records
**`savepoint_limit_exceeded(1024)`**, exposed to the client as
`proof_unavailable`. The destination height remains unchanged. Selecting each
deterministic answer with ordinary `once/1` still reaches that limit.

The final [attributed probe](source-composition-08/check.log) and its
[true exit](source-composition-08/result.json) retain this failure. Trying to
execute a compiler's opaque body locally fails the existing callable
materialization contract; it is not a supported installation path and is not
used by production. No admission limit was raised, deadline extended, proof
check bypassed or domain transition split.

Treating that bulk edit as a prerequisite was premature. The existing source
editor supports installing definitions while simulation is explicitly disabled.
[inactive-installation-01](inactive-installation-01/result.json) verifies the
complete 55-definition replacement through that ordinary signed path. Every
edit checks the disabled state and exact expected source, commits through the
existing owner, reads back the expected definition and preserves the original
world anchor and four body definitions. No simulation is allocated during any
step. All 55 updates passed, with a true child exit of zero.

This is code installation during explicit inactivity. Physical actions and
their checkpoints, events and receiver consequences remain atomic. The live
installation must quiesce the existing owner and resolve any original pending
operation before updating its rules, then activate only the complete program.
No runtime wrapper, compatibility fork, additional executor, polling loop or
admission-limit change is required. The bulk-update refusal remains a separate
shared admission issue; it no longer blocks this ticket.

## Clean release validation

[release-264-gates-01](release-264-gates-01/receipt.json) passed all eleven
standing sequential gates on 1,039 unchanged frozen inputs: 35 native tests in
each build profile, Clippy, 134 client cases, UI build/lint, 3,919 EUnit tests,
146 Common Test cases, xref, Dialyzer and production release assembly. Full logs,
actual exits and the Common Test archive are retained. The isolated tree has
the proposed 0.7.264 label; implementation and label commits are separate: `d2c419cf` and `f527384e`.
The initial launcher pointed at an old campaign and failed before any gate
ran; its failure is retained and the old campaign was untouched.

## Retained failures and remaining work

Every completed campaign retains its full log, source fence and actual child
exit. Focused view campaigns 01–03 and 05 failed; their triage explains the
incorrect command, unavailable authored view, unevaluated negative attachment
offset and noncanonical test variables. Campaigns 04 and 06 passed. Assertions
were not weakened. The broader owner campaign passed after these corrections.

Source-composition campaigns 03–10 retain fixture failures, exact source guards,
admission refusals and unsupported local-body execution. Earlier attempts are
not presented as successful installation. The first live inventory probe's
Erlang eval returned a syntax error despite Nomad's child exit zero; the Python
probe rejected it. The separately labelled corrected inventory completed.

## Live findings and handoff

[Deployment evidence](deployment-264/release/PASSED.json) records candidate
version 73, eight healthy allocations, zero restarts, unchanged main/ingress,
and retained node identities, volume placements, TLS certificate and exact
historical blocks. The pinned image is 0.7.264, digest
`c0c5ee860c2a7234991f350eb6980cafd184fcb64631dd7c17871df2af9dd244`.

Both worlds received the same 55 shared predicate replacements through the
ordinary signed editor while inactive. Every edit checked expected source,
inactivity, anchor and original bodies. Authored definitions and policies then
provisioned each example atomically through the shared mechanics. No old door
implementation remains in either retained ontology.

The real personal console accepted door closes. Obstacle 7 stopped the first
and final placements at 564 mrad, with committed blocked results and matching
checkpoints. [Actual rendered transforms and frames](live-01/personal-front-blocked-visible.rendered.json)
and [the ordinary screenshot](live-01/personal-front-blocked-visible.png) retain
the final stop. Simulator loss restored the first blocked checkpoint without
repeating consequences. Intermediate placement contacted the unchanged roof
and correctly committed blocked(3); that result is retained, not a passed
obstacle-7 check. Shared group/obstacle moves fenced earlier revisions.

The independent gallery has an authored compound lid with an X-axis hinge,
400 mrad target, rotated attachment frame, handle, policy and ordinary console
view. It is enabled and idle; its real normal-view close has **not** been run.
Personal-world clearing/closed completion, full live recovery, lost-reply
resolution and cross-world normal-view isolation remain unverified.

[Final readback](live-01/pause-current-state.owner.json) records personal height
272, sequence 3, blocked(7), joint/body revision 6, checkpoint 564 mrad; gallery
height 97 and lid sequence 0/idle. [Layout verification](live-01/pause-original-layout-verification.owner.json)
confirms all four original body definitions are byte-identical and the exact
six-mark lobby prefix remains. Browser cleanup exited zero; its private profile
and identity are retained outside this archive.

[The unchanged-work measurement](live-01/personal-unchanged20-before-update.owner.json)
failed acceptance: twenty real owner checks called geometry/1 **140 times**.
Watched native installs/controls, ledger folds/opens, projection applies and
storage writes/syncs were zero. Runtime physics_projections/2 unconditionally
parses the selected rows, rebuilding geometry descriptions before comparing
installed specs. Reuse must be repaired in the existing owner and measured
again, including a real update. No engine patch was made. The attempted real
update tracer missed its readiness signal and stopped **before submitting**
the obstacle clear; its stop marker is retained.

Other retained harness failures include invalid literals/variables, an expired
original request, React-field replacement, transient session expiry and a
renderer capture of the wrong module instance. Corrected campaigns are
separately labelled. The expired request was never given a new deadline or
resubmitted; its fresh successor followed conclusive expiry. Stale captures
are not used as final pose evidence.

The separate bulk source-update issue is published as stable tracker id
`bug_1791807061434_iovrco`; this workspace cannot assign it a shared issue key.
It does not block the supported inactive installation route. QUD.36 stays open.
No additional test cycle is needed for this evidence-only handoff: the current
production code is exactly the already gated and committed implementation.
