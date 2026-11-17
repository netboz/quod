# Phase 1 signed reader: intermediate failure report

Phase 1 remains incomplete on `worktree/pearl-stone`, based on 0.7.282.
No commit, version bump, deployment, refound or live edit has run. This report
retains a failed implementation increment; it is not a clean phase boundary.

## Implemented within the approved reader scope

Yan approved ordinary signed, read-only physics reads with ACL checks, original
deadlines and reuse of verified data. The existing ingress now accepts a private
committed-read restriction at the local signed origin. The existing scope
selection carries that restriction through nested calls. Live queries, staging
and reaction commands are refused; the node's ordinary signed identity and all
scope ACLs remain in force.

Physics and agent-host selection use that reader because they share physical
eligibility. Source-body and frame reads use it too. The obsolete raw retained
source reader and `resource_selection` context were removed. The existing
strict local custody and committee-verdict restrictions remain unchanged.
The first implementation retained computed read results in another runtime map.
That extra cache was removed. The runtime now uses its existing resource basis,
source follows and single pending installation reply; the proof owners retain
verified data. No process, resource budget or population limit was added.

The retired `resource_selection_identity_has_no_live_or_scope_authority_test`
covered the superseded local-only context. Its still-valid identity, ACL,
write/live-query/reaction refusal obligations are covered through the real signed
path by `committed_signed_read_preserves_bindings_and_scope_restrictions_test_`.
The hosting fixture now starts the existing foreign-log owner once, and the
nested fixtures no longer start duplicate owners.

## Verified results and failures

Commands, timestamps, true child exits and absolute log paths are retained in
[results.jsonl](results.jsonl). Each failed run was reported before any rerun.

- `signed-resource-read-01`: exit 1, 54 tests. Fixture expected all ancestry
  alternatives from an API returning the first answer. The query was made exact.
- `signed-resource-read-02`: exit 1, 54 tests. Fixture expected a top-level
  error; the actual result correctly retained read dependencies and `read_only`.
- `signed-resource-read-03`: exit 0, 54 tests. Signed restriction, source view,
  ingress and scope-wire coverage passed.
- `runtime-reader-compile-01`: exit 0.
- `runtime-class-reader-01`, `runtime-class-reader-diagnostic-02`, and
  `runtime-class-reader-diagnostic-03`: exit 1 each, one test each,
  `physics_not_installed`. A failed read had recorded an absent cache entry as
  a dependency, causing immediate reselection. That cache has since been removed.
- `runtime-class-reader-04`: exit 1, one test. The now-visible error was
  `{resource_selection_failed,invalid_goal}`. The signer needs numbered variables;
  the reader now uses the existing term numbering and maps returned bindings back.
- `runtime-class-reader-05`: exit 1, one test. World creation succeeded, but
  activation remained `{unavailable,activation_not_sent}`. The fixture granted
  the node's class read but not the physics agent's same read. Its exact public
  read grant now covers both principals.
- `runtime-class-reader-06`: exit 0, one test. Class-owner updates and ACL
  withdrawal changed actual installed physics; unchanged repeats caused no
  storage I/O.
- `runtime-class-reader-07`: exit 0, one test. The same obligations passed
  after removing the extra result cache.
- [signed-resource-cleanup-01.log](signed-resource-cleanup-01.log): **exit 1,
  293 tests, 34 failures**. Full output remains intact; the readable failure
  index is [signed-resource-cleanup-01-failures.txt](signed-resource-cleanup-01-failures.txt).

  ```text
  Finished in 213.633 seconds
  293 tests, 34 failures
  ===> Error running tests
  ```

  Examples from that run:

  ```text
  signed_live_body_predicate_test_: expected {ok,_,{0,0,0},...}; got {error,unavailable}
  live_source_busy_owner_coalesces_test_: ?assert(Queued =< 2); got false
  hosted_agents_exchange_committed_events_test_: source_view_not_ready
  physical_loss_drives_signed_policy_and_host_activation_test_: {badmatch,{error,eperm}}
  interrupted_initial_physics_selector_reselects_test_: selector_not_retired
  ```

  Two `eperm` failures occur at the physical-loss fixture's network setup.
  The exact-source-count fixture also assumed only one followed source; signed
  authorization now retains the node's dependency as well. Other failures remain
  to be triaged individually. None is waived.
- After that failure, the existing completion check was corrected to consult
  its conservative parent dependency only when actual queued changes exist.
  Interrupted selections retain their already-known source dependencies and
  wake on source readiness through the existing failure/basis state. Those
  corrections are **compile-checked only**, not claimed behavior-verified.
- [runtime-reader-cleanup-compile-01.log](runtime-reader-cleanup-compile-01.log):
  exit 0.
- [signed-reader-whitespace-01.log](signed-reader-whitespace-01.log): exit 0.

Full clean Phase 1 EUnit, CT, Dialyzer, xref and client gates have **not run**.
There are no full-gate exit codes to report for Phase 1. The existing Phase 0
browser rejection remains recorded separately.

## Remaining correctness issue

The current signed read reports each visited ontology's exact height, but does
not return the predicate reads already recorded by its proof sessions. The old
runtime observed individual predicates. Substituting whole-ontology dependencies
makes an unrelated local edit invalidate physics immediately. For example,
changing a body-read ACL makes an unchanged native body unavailable in
`signed_live_body_predicate_test_`. This also broadens resource wakeups.

The requested behavior needs precise reads carried back through the existing
signed-read result and used by the existing invalidation owner. No replacement
cache, copied class program, new process or relaxed assertion is proposed.
Yan's instruction requires stopping before an unplanned code-path extension;
a decision on that result extension is pending. No implementation of that
extension has been written. The domain owner moves remain untouched.

## Measured production lines

[signed-reader-delta.json](signed-reader-delta.json) reconstructs the pre-Phase-1
production tree from HEAD and `before.patch`, then compares actual files.
Phase 1 so far: **+483 / -251, net +232**. Cumulative against HEAD:
**+641 / -441, net +200**. Tests, docs, plan and evidence are excluded. This is
an incomplete engine/reader increment; the planned domain deletions have not
landed. Growth is primarily signed-read restriction propagation and dependency
installation, partly offset by removing the obsolete source reader/context.

The first measurement exited 1 before producing numbers because its include
filter preceded the test exclusion:

```text
AssertionError: error: client/godot/tests/ExportChecks.cs: No such file or directory
```

[signed-reader-measurement-01.log](signed-reader-measurement-01.log) retains that
failure. The corrected reconstruction exited 0, retained in
[signed-reader-measurement-02.log](signed-reader-measurement-02.log). Neither
measurement modified the worktree's production files.

## Every normative Markdown sentence changed in this increment

The exact diff is [signed-reader-doc-diff.patch](signed-reader-doc-diff.patch).
Only `doc/runtime-and-agents.md` changed in this increment.

Replaced:

> Their execution context distinguishes normal proofs, validator policy checks, local installed-resource selection and read-only reaction matching; an invalid context fails closed.

With:

> Their execution context distinguishes normal proofs, validator policy checks and read-only reaction matching; an invalid context fails closed.

Removed:

> The resource selector remains local and read-only.
>
> When resolving a retained source it may use `resource_selection` context with that owner's exact namespace, anchor and snapshot height.
>
> Only proof-bound metadata queries are permitted; live queries, scope calls, staging and reaction commands are forbidden.
>
> This lets a source recipe identify its own anchored frame without network I/O or an authenticated principal.
>
> Committed `policy_verdict` checks retain their stricter bridge prohibition.

Added:

> Physics and agent-host selection use ordinary node-signed, read-only proofs with committed queries and the original caller deadline.
>
> Class-owner and source reads follow the normal scope path and ACLs; live queries, staging and reaction commands remain forbidden.
>
> The existing proof owners retain verified data, while the runtime retains the returned dependencies and follows certified source progress before installing the selected resources.
>
> Unchanged checks do not rebuild history or write storage.
>
> Other local resource selectors and committed `policy_verdict` checks retain their stricter bridge prohibition.

Source API documentation adds “Restrict a local signed read to committed queries
and its caller's original deadline.” in `quod_client_goal_ingress`. The
`quod_predicates` context-kind sentence removes the obsolete `resource_selection`
entry; its `resource_context/2` sentence “Local installed-resource selection with
an owner-supplied immutable identity.” is deleted. Earlier shared-engine and
presentation doc changes remain listed in their existing reports. Plan status
text records authorization and this incomplete result; no final decision or
checklist item is changed by this increment.
