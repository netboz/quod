---
planStatus:
  planId: plan-explicit-failure-reasons
  title: Failure reasons stated by Prolog rules
  status: draft
  planType: bug-fix
  priority: high
  owner: Yan
  stakeholders: []
  tags: [erlog, prolog, failure-reasons, consensus]
  created: "2026-11-18"
  updated: "2026-11-18T15:33:27.677014Z"
  progress: 0
---

Remove automatic failed-call recording from erlog. Prolog rules state actionable
refusals with `fail_with_reason/1`. Keep ordinary failure, backtracking, cut,
authorization, atomic writes and recovery under their existing owners.

This is a proposal for Yan's approval. No production source, test or spec has
been changed. Measurements use a disposable engine and frozen Quod source.

## Implementation checklist

- [ ] Approve the semantics and the replacement spec text below.
- [ ] Change the erlog fork and update its tests; obtain approval for its commit.
- [ ] Update Quod's pin and affected tests and rules; apply the approved spec text.
- [ ] In a separate phase, share unchanged dereferenced terms; verify proof semantics and memory before including it in the release.
- [ ] Pass the clean server gates and scene measurements on the exact release tree.
- [ ] Review the finished change, then obtain separate commit, push and release approval.
- [ ] Perform the approved coordinated release; no refound or data deletion without Yan's word.

## Authority and measurements

The settled direction and previous measurements are recorded in [QUD.85](nimbalyst://QUD.85).
Source sessions are `d3f86a98-d586-420b-9b66-490a53d78ad1` and
`c310f254-9bac-4053-8e63-da8638a43c00`. Yan authorized this session to continue
their investigation. After the load check, he said he had stopped Project Zomboid.
The parent session also requested a GPT Sol review of the plan.

The experiment changes only a copied `erlog_int.erl`: procedure dispatch does
not push `predicate_failure` choice points, and automatic recording is a no-op.
It retains the explicit reason implementation and the original deep
dereferencing. The engine's 121 standalone EUnit tests ran unchanged: 112 passed
and nine failed because they assert automatic entries or retained boundaries.
The full `rebar3 eunit` attempt failed at compilation because the old
[records_test.erl](/home/yan/src/erlog/test/records_test.erl) requires unavailable `eqc` headers. That failed attempt is
retained; the standalone run is not a claim that those properties ran.

The [measurement report](../../doc/evidence/failure-reasons-20261118/report.md)
keeps all exits and results. The unchanged Quod EUnit run reported 4,323 tests,
341 failures and one cancelled fixture. Its
[complete failure inventory](../../doc/evidence/failure-reasons-20261118/eunit-failures.md)
records each case and distinguishes direct dependencies from fixture fallout.
Common Test completed all 150 cases: 116 passed and 34 failed. Fresh-VM
follow-ups passed the contaminated network, receipt and historical-transaction
modules. Two isolated failures confirm an automatic trace expectation and a
wrapped empty-list expectation. Every case is in the report.

The corrected six-case scene probe completed; its deliberately stopped first
attempt and diagnostic are retained separately. The rendering test passed in
2.407 seconds under its existing five-second limit. Valid 300/600/1200-mark
proofs took 0.461/1.358/4.527 seconds; refused cases took
0.348/0.984/2.793 seconds. All six retained zero reasons. The valid 1200-mark
result still held 1,098,557,560 process bytes after GC. This remaining cost
changes the release recommendation below.

## Engine change

Repository `/home/yan/src/erlog`, branch `quod`, starting at
`79b3874617a4eb9f76d5089a3fc908667e605e8a`.

In [src/erlog_int.erl](/home/yan/src/erlog/src/erlog_int.erl):

- Pass the current state directly to built-in, external and clause execution.
- Undefined procedures under `unknown=fail` fail without recording a call;
  `unknown=error` still throws its existing existence error.
- Remove `predicate_failure_boundary/2`, `add_predicate_failure_reason/2`,
  `internal_predicate/1`, `freeze_failure_term/1` and the matching
  `fail_choicepoint/3` clause. They serve only automatic diagnostics. No stub
  or second path remains in production.
- Keep `add_failure_reason/2`, `valid_failure_reason/1` and
  `merge_failure_reasons/2` as the existing host/remote bridge. Prolog cannot
  carry a result out of a failed alternative through ordinary bindings.

In [src/erlog_bips.erl](/home/yan/src/erlog/src/erlog_bips.erl), keep `fail_with_reason/1` and `get_fail_reasons/1` with
their current implementation. A reason is fully dereferenced when explicitly
recorded. A non-ground term raises `instantiation_error`; a non-portable term
raises `domain_error(failure_reason, Term)`. The generic API accepts portable
ground terms; Quod's atom or operation/detail convention remains an authoring
rule rather than a new engine restriction.

The retained list is newest first. `fail_with_reason(R)` prepends R and fails
through normal backtracking. Repetition of ordinary reasons records repetition;
there is no deduplication, size limit, count limit or depth limit in native
reason admission. The existing reserved atom `fail_reasons_truncated` retains
its current marker behavior: it is recorded once and sets the existing flag,
including when received through remote merge. It is not an ordinary domain
reason. `get_fail_reasons(Rs)`
unifies Rs with the list, adds nothing and does not clear it. A failed
unification adds nothing. Failure histories survive alternatives, transaction
rollback, negation, `findall/3` and cut. A successful proof can therefore retain
explicit reasons from abandoned alternatives. A fresh `prove_goal/2` invocation
resets its list; asking for the next solution with `fail/1` does not reset it.
An ordinary failed call, exhausted successful call or internal helper adds
nothing, including inside negation and collectors.

The existing optional host admission callback and its truncation state are not
used by Quod production. Do not expand this change into removing that independent
API: native admission remains unlimited. The callback-only tests still cover
their existing contract. This experiment does not measure or authorize a
different invalid-reason or custom-policy contract.

Update [doc/user_guide.txt](/home/yan/src/erlog/doc/user_guide.txt) in the erlog fork too: its current failure-reason
section promises automatic frames and obsolete byte/frame quotas. Replace those
claims with the explicit recording, native admission and reserved-marker
contract above. No runtime or wire envelope bound is relaxed by this change.

The full replacement between its `FAILURE DIAGNOSTICS` and `ERLANG INTERFACE`
headings is:

```text
fail_with_reason(Reason) resolves and records a ground portable diagnostic term
and immediately fails. A non-ground term raises instantiation_error; a
non-portable term raises domain_error(failure_reason, Term).
get_fail_reasons(Reasons) unifies Reasons with the complete current proof's
newest-first failure list without adding or clearing reasons. Ordinary failed
or exhausted predicates add nothing. Reasons survive backtracking, cut,
negation and findall; a new top-level proof starts with an empty list.

Native admission has no byte, entry-count or nesting-depth quota. Host admission
callbacks retain their existing separate API. The reserved atom
fail_reasons_truncated retains its existing marker behavior and appears at most
once when explicitly recorded or when a host admission policy rejects an
entry. It is not an ordinary application reason. Removing automatic boundaries
does not introduce a truncation policy.
```

### Engine tests

In [test/erlog_failure_reasons_tests.erl](/home/yan/src/erlog/test/erlog_failure_reasons_tests.erl), rewrite these nine tests:

| Existing test | Replacement obligation |
| --- | --- |
| `standard_predicate_gets_default_reason_test` | `atom(42)` fails with `[]`. |
| `nested_predicates_form_failure_trace_test` | Nested ordinary failures retain `[]`. |
| `explicit_reason_is_root_cause_of_trace_test` | Only `impossible_to_link(bob)` remains. |
| `internal_predicates_do_not_pollute_failure_trace_test` | Neither internal nor public wrappers add reasons. |
| `unbound_default_arguments_are_frozen_test` | Unknown failure retains no reason; no `unbound` substitution is invented. |
| `non_prolog_default_arguments_are_sanitized_test` | Unknown failure retains no reason; no `opaque` substitution is invented. |
| `successful_negation_retains_automatic_trace_test` | Successful negation of ordinary failure retains `[]`. |
| `successful_findall_retains_automatic_trace_test` | Empty ordinary generator retains `[]`. |
| `successful_call_boundaries_are_retained_test` | Successful calls retain no automatic choice points; exhausting them also records nothing. |

Keep all other tests. In particular keep explicit order, cut, fresh proof,
negation, collector, portability, large terms, stack preservation and remote
merge tests. Rename the manually inserted `outer_frames_preserve_a_large_inner_reason`
test to say that it tests explicit host insertion; its large-reason obligation
remains. Do not delete coverage to make the engine suite green. Record the
missing QuickCheck dependency and get the legacy properties runnable at the
verification boundary, or report them as a blocker rather than claiming a full pass.

## Quod readers and owners

| Path | Treatment |
| --- | --- |
| [src/quod_proof_scope.erl:drive/3](/home/yan/src/quod/src/quod_proof_scope.erl) | Keep returning the exact list, including `[]`, from the interpreter. |
| [src/quod_proof_session.erl:first_result/2](/home/yan/src/quod/src/quod_proof_session.erl) and `finish_step/4` | Keep the same list through invocation completion. No fallback or synthetic call entry. |
| [src/quod_prolog.erl:proof_reply/2](/home/yan/src/quod/src/quod_prolog.erl) | Keep the existing mapping of `{fail, []}` to bare `fail`; reasoned failure stays `{fail, Reasons}`. Fix callers/tests that wrongly assumed all failures were reasoned. |
| [src/quod_erlog_db_local_prove.erl:fresh_proof_state/1](/home/yan/src/quod/src/quod_erlog_db_local_prove.erl), `committed_state/1` | Keep resetting proof-local reasons for fresh invocations; overlay rollback still preserves the active proof's explicit list. |
| [src/predicates/quod_ask.erl:drive_stream/5](/home/yan/src/quod/src/predicates/quod_ask.erl) | Merge explicit remote reasons in their existing order, then fail normally. Empty remote lists are valid. Local and remote asks use the same path. |
| [src/quod_scope_wire.erl](/home/yan/src/quod/src/quod_scope_wire.erl), [src/quod_wire_term.erl](/home/yan/src/quod/src/quod_wire_term.erl) | Keep the existing possibly-empty reason codec and opaque remote symbols. No wire version change or new quota. |
| [src/quod_client_result.erl](/home/yan/src/quod/src/quod_client_result.erl), [src/quod_client_http.erl](/home/yan/src/quod/src/quod_client_http.erl) | Keep the existing plain-failure and reasoned-failure forms; both render `result: fail`. Preserve read dependencies and outcome evidence. |
| [src/quod_runtime.erl:resource_read_result/2](/home/yan/src/quod/src/quod_runtime.erl), `select_resource_result/4` | Keep the existing `no_solution` wrapper and predicate indicator. Its inner list may be empty. Optional absence remains plain failure. |
| [src/quod_effect_journal.erl:desired_state/3](/home/yan/src/quod/src/quod_effect_journal.erl) | Add bare `fail -> absent` beside the existing tagged failure case. Otherwise a missing desired fact becomes unavailable and stalls a durable effect. Keep unavailable/error outcomes distinct. |
| [src/predicates/quod_gui_predicates.erl:stage/3](/home/yan/src/quod/src/predicates/quod_gui_predicates.erl) | Keep `gui_open_failed(Reasons)`, including `[]`. Its owner already states which operation failed. |
| [src/quod_predicates.erl:fail_reason/2](/home/yan/src/quod/src/quod_predicates.erl), direct host insertions in [src/predicates/quod_common_primitives.erl](/home/yan/src/quod/src/predicates/quod_common_primitives.erl) | Keep explicit grounded reasons. These use the same engine facility. |
| [src/quod_outcome.erl](/home/yan/src/quod/src/quod_outcome.erl), [src/quod_dtx_recovery.erl](/home/yan/src/quod/src/quod_dtx_recovery.erl), [src/quod_explorer_http.erl](/home/yan/src/quod/src/quod_explorer_http.erl) | Preserve exact committed reasons; do not recompute or rewrite historical lists. |
| `client/godot`, `client/src` | Result-class handling remains valid. No client should assume an automatic frame or a non-empty reason list. Confirm with the changed server fixtures; do not add a second presentation path. |
| [scripts/release/refound/quod_refound_operator.erl:user/0](/home/yan/src/quod/scripts/release/refound/quod_refound_operator.erl) | Expect bare `fail` for the pre-grant absent root-administrator fact; preserve the existing successful signed grant and post-grant proof. |
| [scripts/release/refound/fleet-verify.erl](/home/yan/src/quod/scripts/release/refound/fleet-verify.erl) | Replace four comparisons against `{fail, []}` with positive successful-answer checks. Those comparisons already accept failures and errors as success; a fleet must satisfy the queries. |
| [scripts/release/quod_source_release.erl:apply/4](/home/yan/src/quod/scripts/release/quod_source_release.erl) | Existing reasoned error formatting stays valid; its catch-all already preserves plain failure. No synthetic call frame is needed. |

All production `get_fail_reasons/1` ontology uses: none in the checked-in
ontologies. Explicit `fail_with_reason/1` uses remain under their existing
ontology owners. The measurement report supplies the affected test inventory,
including tests that pattern-match automatic entries and those that assume
`{fail, _}` when the correct existing result is now bare `fail`.

### Quod test changes

Use the measurement report's complete failed-case list as the implementation
checklist; it identifies the files. Preserve each test's actual obligation:

- For ordinary recognizer, missing-fact and rolled-back-write proofs through
  the public API, assert bare `fail`. Do not weaken them to accept errors or
  every failure shape. Calls directly to `erlog_int` still return `{fail, St}`;
  calls to the internal proof session still return `{fail, []}`.
- In [test/quod_ask_tests.erl](/home/yan/src/quod/test/quod_ask_tests.erl) and [test/quod_ask_SUITE.erl](/home/yan/src/quod/test/quod_ask_SUITE.erl), remove expected
  automatic local/remote call frames. Recover by matching the explicit reason
  with its arguments. Retain local/remote symmetry, opaque-symbol handling,
  nested refusal and logical fallback behavior.
- The remote deep-failure fixture currently gets its long list from recursive
  automatic frames. Rewrite that fixture to state its reasons explicitly on
  failed alternatives before continuing recursion. Keep the more-than-former-
  quota transport obligation and newest-first ordering. Do not merely delete
  the long-stack check. A single deeply nested explicit reason remains whole.
- For runtime wrappers, assert the same `no_solution` operation/indicator and
  an empty inner list when the selector states nothing. For explicit domain
  refusals, preserve their exact reason/arguments; no synthetic wrapper entry.
- Keep codec, large-term, action-candidate and atomic refusal/outcome/recovery
  tests that already exercise explicit reasons. In the transaction rollback
  test, remove its expected automatic `transaction(...)` entry and assert the
  surviving explicit list `[rejected_candidate]` exactly.
- Update the existing test helpers in [test/quod_agent_hosting_tests.erl](/home/yan/src/quod/test/quod_agent_hosting_tests.erl),
  [test/quod_gui_menu_tests.erl](/home/yan/src/quod/test/quod_gui_menu_tests.erl) and [test/quod_physics_tests.erl](/home/yan/src/quod/test/quod_physics_tests.erl) where they
  destructure every result as a tuple or require an encoded failure list even
  when asserting that the explicit-reason count is zero. In the menu helper,
  `{read, _, fail}` must remain an ordinary negative view with an empty list.
  Preserve all positive reason-count assertions and explicit reasons.
- Triage any timeout, setup failure or unrelated assertion separately. An
  incomplete fixture's cancelled cases are not passing tests. The unchanged
  experiment's lifecycle setup failure at #169 leaves its router, foreign log,
  journal, live root and signing configuration behind before the test enters
  its cleanup block. This explains later registration/network errors. Do not
  weaken consensus, certificate, receipt or identity checks to make them pass.
  Confirm those cases in fresh VMs; after the journal fix rerun the complete
  clean suite. If partial setup can still leak, fix cleanup at that existing
  fixture boundary without introducing production recovery workarounds.

### Atomic writes: no missing entry to manufacture

The handoff's claim that a Prolog failure currently supplies atomic votes'
non-empty lists is not supported by the current code:

1. `quod_proof_session:first_result/2` returns `{fail, Reasons}` on exhaustion.
2. `quod_prolog:finish_pinned_proof/4` seals only `{ok, ...}`. Failed proofs
   close without sealing and never enter Vote/Resolve/Complete.
3. After a successful proof has sealed, `quod_commit_validation:vote_choice/3`,
   `source_claim_status/2` and `own_vote_choice/4` choose a deterministic
   rejection and explicitly form `[Reason]`: for example `vote_deadline`,
   `invalid_agent_key`, `conflict_retry`, `duplicate_operation` or
   `operation_conflict`.
4. `quod_atomic:select_vote/2` and `new_vote/4` encode those reasons.
   Resolve derives abort from a certified refused vote; outcome, recovery and
   terminal waiters carry its committed list.

Keep non-empty validation in `quod_atomic:new_vote/4`, `resolution_result/1`,
`select_vote/2`, `quod_outcome:valid_reasons/2` and
`quod_prolog:valid_terminal_reasons/2`. Their producer already owns the reason.
No generic `no_solution` entry, new service or relaxed validation is needed.
The Quod suite must confirm this trace before approval.

## Rules that must state reasons

Do not add reasons to search predicates, list traversal, schema recognizers or
ordinary policy falsity merely because their call entries disappear. That
would recreate the same cost in Prolog and change ordinary failure into a
reasoned refusal. `well_formed_scene/1`, `every_mark/1`, `member/2` and the
rendering recognizers therefore stay ordinary predicates.

Permission denial already becomes `fail_with_reason(not_allowed(Namespace))`
in `quod_proof_session`'s invocation guard. Existing explicit refusal rules
for constructors, physics, custody, GUI conflicts, source editing and voxel
worlds remain explicit. No production rule is known to inspect automatic
frames. Complete the test-driven check before asserting that no additional
domain refusal needs an authored reason.

Add regression coverage at the existing `test_desired_state` seam in
[test/quod_lifecycle_single_path_tests.erl](/home/yan/src/quod/test/quod_lifecycle_single_path_tests.erl), and through the durable-effect
lifecycle: an absent fact starts execution, post-execution absence reports
postcondition failure, existing-effect absence reports incompatible local
state, and a genuine unavailable owner remains unavailable. Explicit refusals
continue to mean logical absence here. Preserve the no-double-execution
obligation when desired state is already satisfied. This is a consumer fix,
not a reason to make ordinary ontology facts emit refusals.

## Proposed spec text

Only after approval, in [doc/proofs.md](/home/yan/src/quod/doc/proofs.md), replace the two sentences beginning
"The engine also retains failed predicate calls" with this complete paragraph:

> The engine records only explicitly stated refusal reasons. An ordinary
> failed predicate call adds nothing, including when a previously successful
> call is exhausted by backtracking. `fail_with_reason(Reason)` resolves and
> checks one ground portable term, records it, and fails through ordinary
> Prolog backtracking. A non-ground reason raises an instantiation error; a
> non-portable reason raises a failure-reason domain error. `get_fail_reasons(Reasons)`
> unifies `Reasons` with the complete list, newest first, without adding or
> clearing anything. The engine's existing reserved `fail_reasons_truncated`
> atom remains a marker recorded at most once; domain code must not use it as
> an ordinary refusal reason. Explicit reasons survive failed alternatives, transaction
> rollback, negation, collectors and cut; they can remain in a proof that later
> succeeds. A fresh proof starts with an empty list. Quod uses native reason
> admission with no size, count or depth limit on reasons; existing request,
> runtime and encoding constraints remain separate. A proof that states no
> reason may fail with an empty list.

Immediately after that paragraph, add:

> Ordinary proof failure closes the proof without sealing its staged writes.
> A refused atomic Vote is a different result: commit validation supplies its
> deterministic reason after a successful proof has sealed its plans. Refused
> Votes, abort resolutions and their terminal outcomes still require a non-empty
> list. They do not depend on automatic failed-call entries.

Keep the surrounding three result classes, owner replies, error allowlist,
caller deadlines and client uncertainty rules unchanged. The existing domain
authoring convention remains in force. Do not edit specs as a side effect of
the experiment.

## Goal dereferencing is a separate phase in the same release

Keep the `prove_goal/3` deep-dereferencing optimization in a separate
implementation and verification phase after the explicit-reason change.
The prior measurements found that sharing unchanged arguments
reduced retained memory from 915 MB to 23 MB and valid 600-mark time from
1.59 s to 1.12 s in the lazy-reason variant. Those figures do not measure the
explicit-only engine. This experiment supplies that baseline: the valid
1200-mark result still retains about 1.10 GB even with no automatic reasons.
Recommend including the separate sharing phase in the same release, after it
passes its own semantic checks, rather than presenting the first phase as a
large-scene memory fix. Do not skip the semantic phase's checks or merge the
two changes into an unexplained optimization. If sharing cannot be verified,
report the unresolved memory cost to Yan before deciding what to release.

The later change belongs to [src/erlog_int.erl](/home/yan/src/erlog/src/erlog_int.erl)'s existing traversal owner.
Return an unchanged indication from traversal rather than using
`erts_debug:same/2` in production. Measure first-use and repeated operations,
allocations and held memory; preserve aliasing, variable resolution,
backtracking, cuts and all host predicate contracts. Preserve `dderef/2`'s
public return contract and reuse the traversal; do not add a second groundness
walk or a separate dispatch algorithm. Sharing ground terms
still traverses them and does not by itself promise linear-time scene checks.
Approve and test that phase explicitly; the final release gates cover the
combined exact tree. This plan does not implement or claim results for it.

## Verification and release

Before implementation: finish the unchanged-suite experiment, classify every
failure and cancellation, measure 300/600/1200 valid and duplicate-ID scenes,
then obtain the requested independent GPT Sol review of this plan. That review
is consultative and cannot approve code or releases for Yan.

After implementation: erlog's complete runnable suite and the documented
QuickCheck properties; focused reason propagation, rollback, public reply,
authorization and atomic refusal/recovery tests; then the standing clean
sequential gates on the exact tree:

```sh
python3 scripts/release/server-gates.py doc/evidence/<fresh-folder> server-01
```

Retain each child exit and full log. Re-measure the six scene cases after the
gates, on an available machine, with the final result kept alive while sampling
memory. The rendering EUnit test must pass within its existing five seconds
with margin. Do not raise its timeout or silently rerun a failed gate. Exercise
the journal correction through the real owner: existing desired state must
avoid another manager action, an unchanged repeat must not replay history,
rebuild projections or write/sync files, and an actual missing desired state
must execute and apply once. Retain the repeated-create and journal-restart
coverage in the lifecycle suite; measure work rather than latency alone.
Existing OCC, overlay, authorization and recovery tests still run through the
real owners.

The erlog commit is on `quod`; Quod updates the exact SHA in `rebar.config` and
`rebar.lock`. No branch reference and no hidden checkout override ships. All
consumers rebuild against the same record definitions. Ask Yan separately for
the erlog commit, its push, the Quod commit, its push, version-label change and
deployment; previous cleanup approval is not release authority for this work.

This changes observable proof semantics and is consensus-relevant, even though
the reason codec and atomic record shapes do not change. Authored policy can
use `get_fail_reasons/1` to decide whether it succeeds. Old and new engines can
then disagree on authorization, the staged diff or a commit verdict. Never mix
the engines within an active fleet.

Current projection rebuild calls `quod_commit_validation:content/5` and DTX
validation again, which re-prove recorded authorization. Merely preserving old
reason bytes therefore does not prove that every old ledger remains valid.
Recommend a coordinated fleet release and a refound under Quod's existing
greenfield release procedure, unless offline replay of the actual retained
certified histories against the candidate, including foreign projections and
authorization at each historical parent, establishes safe retention. A grep of
current source is not that evidence. No format
change alone forces a refound; the issue is historical proof semantics. There
will be no compatibility engine, migration layer, silent history rewrite or
automatic data wipe. Yan decides and authorizes any refound separately.

Keep the new evidence while this plan/release needs it. Remove the disposable
tree after recording all results. Once implemented, put approved rulings into
[doc/proofs.md](/home/yan/src/quod/doc/proofs.md), file any designed-but-unbuilt work in the tracker, and delete
this plan under the repository's cleanup rule.
