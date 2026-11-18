# Explicit failure reasons: experiment and plan evidence

Quod tree: `a55a3f0889d269ba48fd864ded281ea6799deb51` on master.
Erlog tree: `79b3874617a4eb9f76d5089a3fc908667e605e8a` on quod.
This measures the direction settled in [QUD.85](nimbalyst://QUD.85).
It is not implementation approval or release evidence for a changed product.

## Scope and method

The source snapshot and experimental engine live only under
`_build/failure-reasons-20261118/`. The Quod snapshot is `git archive HEAD`;
cached dependencies are copied, and its erlog checkout points at the disposable
engine. Rust uses the existing derived build cache. Original engine source,
Quod production source, tests, specs and dependency pins are unchanged.

The [manifest](manifest.json) records exact commits, engine source hashes and
starting load. The [experiment patch](engine-experiment.patch) removes the three
automatic-boundary calls from dispatch and bypasses automatic recording for
undefined procedures. No boundary gets pushed; the remaining unused diagnostic
helpers are deliberately not the proposed production implementation. Explicit
recording, remote merge, reason admission and deep goal dereferencing remain
unchanged. No test assertion is changed.

The game was active at the first load check. Yan then reported stopping it;
the next host process check confirmed that Project Zomboid was absent. Load at
snapshot creation was 0.62/1.77/2.43. Suites run sequentially as background plain
commands through [run-gate.py](../../../scripts/release/run-gate.py).
[results.jsonl](results.jsonl) keeps every child exit and its unique label.

The retained measurement tools are
[measure-explicit-failure-reasons.py](../../../scripts/release/measure-explicit-failure-reasons.py)
and [measure_explicit_failure_scenes.erl](../../../scripts/release/measure_explicit_failure_scenes.erl).
Scene cases use the rendering test's marks and committed-MVCC/local-proof
seam. Each case gets a fresh VM and keeps its entire proof result reachable
while measuring process memory after GC. Proof timing excludes setup, GC and
memory inspection. These are observations, not a new resource budget.

## Engine results

The full [erlog-01 run](erlog-01.log) exited 1 before running tests:
`records_test.erl` needs `eqc/include/eqc.hrl`, which is unavailable. The fork's
README documents this legacy QuickCheck dependency. Its property tests did not
run. No assertion was weakened and the failing run was not overwritten.

The separately labelled [standalone EUnit run](erlog-runnable-01.log) compiled
and ran all seven `erlog_*_tests.erl` modules without changing them:
**121 tests: 112 passed, 9 failed, 0 skipped**. All failures are in
`erlog_failure_reasons_tests`:

| Test | What it depended on | Experimental result |
| --- | --- | --- |
| `standard_predicate_gets_default_reason_test` | Automatic `{atom,42}` entry | `[]` |
| `nested_predicates_form_failure_trace_test` | Outer/inner/builtin call entries | `[]` |
| `explicit_reason_is_root_cause_of_trace_test` | Calls surrounding an explicit reason | Only `{impossible_to_link,bob}` |
| `internal_predicates_do_not_pollute_failure_trace_test` | Public outer frame | `[]` |
| `unbound_default_arguments_are_frozen_test` | Automatic `unbound` substitute | `[]` |
| `non_prolog_default_arguments_are_sanitized_test` | Automatic `opaque` substitute | `[]` |
| `successful_negation_retains_automatic_trace_test` | Automatic entry retained through negation | `[]` |
| `successful_findall_retains_automatic_trace_test` | Automatic entry retained through collector | `[]` |
| `successful_call_boundaries_are_retained_test` | 306 automatic choice points after success | 0 |

The other 16 failure-reason tests passed, including explicit retention,
newest-first order, cut, fresh proof, negation, collector, large reasons,
portability and remote merge. The other 96 EUnit cases passed, covering
checkpoints, predicate-owned choice-point state, cut/collector behavior,
observation transparency, source I/O and opaque functors.

## Quod EUnit

The unchanged [Quod EUnit run](quod-eunit-01.log) exited 1: **4,323 tests,
341 failures, one cancelled fixture**, in 692.809 seconds after compilation.
The [complete numbered inventory](eunit-failures.md) records all 341 cases,
their source files, their log lines and their observed failure classes.
[eunit-failures.json](eunit-failures.json) keeps the same mapping as data.

| Class | Failures |
| --- | ---: |
| Public plain failure asserted as tagged failure | 92 |
| Normalized plain failure asserted as encoded reason list | 61 |
| Test helpers assume tuple/encoded failure, including a zero-reason count | 6 |
| Fallback rule matches automatic frames | 2 |
| Exact list includes an automatic wrapper | 2 |
| Lifecycle operation stalls through effect journal's absence handling | 6 |
| Later duplicate-owner, identity and network/receipt fixture contamination | 172 |

The six lifecycle failures are #164–169. In #169, setup creates and unlinks
the router, foreign log, journal and other owners, then waits for an actor
ontology before the test enters its cleanup block. The failed direct effect
leaves that setup alive. Later failures show its consecutive owner PIDs;
the leaked root anchor also appears byte-for-byte in the wrong-network vote
and authorization results. This is not evidence that the engine now needs to
supply generic atomic refusal entries. The fresh-VM follow-ups below subsequently passed the generic
`invalid_transaction` cases without changing engine or validation assertions.

The cancelled lifecycle fixture fails at setup with that already-started
router. Its remaining cases did not run. The runtime selector test that
asserts a nonempty inner `no_solution` list was itself blocked by this setup
contamination; it is included in the isolated follow-up.

The source inventories are retained in [Quod uses](quod-consumers-01.log) and
[erlog uses](erlog-consumers-01.log). These are cross-checked against the real
proof-session/public-reply distinction, not treated as a count of independent
semantic consumers.

## Common Test

The unchanged [Common Test run](quod-ct-01.log) exited 1: **116 passed,
34 failed, all 150 cases completed**. Every failed case is listed with its
source and log line in [ct-failures.md](ct-failures.md), with the same data in
[ct-failures.json](ct-failures.json).

| Class | Failed cases |
| --- | ---: |
| Ordinary failure asserted as tagged failure | 14 |
| Normalized plain failure asserted as encoded reasons | 3 |
| Fallback/list expectation relies on automatic frames | 4 |
| Durable effects stall through the journal's absence handling | 4 |
| Ordered growth/join cases lack saved configuration after an earlier failed assertion | 9 |

The deep explicit reason itself arrived intact. Its test failed because it
expected an automatic outer frame at the head. The recursive deep-list fixture
must instead state its entries explicitly to keep testing long-list transport.
Growth and join assertions stopped their ordered cases before returning saved
configuration; the following nine cases are recorded failures, not newly
demonstrated consensus defects. The generated retry specification was not used.

The complete CT suite and case logs are retained under `ct-logs`. Temporary
ledgers, caches and generated test identities under `log_private` are excluded;
they are disposable runtime data, not a second evidence archive.

## Isolated checks

The separately labelled [isolated-01 run](isolated-01.log) ran each target in
a fresh VM against the same experimental engine and unchanged tests:

| Module | Result |
| --- | --- |
| `quod_operation_claim_tests` | 9 passed |
| `quod_operation_receipt_tests` | 7 passed |
| `quod_outcome_endpoint_tests` | 26 passed |
| `quod_prolog_scope_target_tests` | 17 passed |
| `quod_retained_dtx_renewal_tests` | 7 passed |
| `quod_retained_dtx_vote_order_tests` | 3 passed |
| `quod_suffix_material_tests` | 8 passed |
| `quod_proof_trace_tests` | 5 passed, 1 failed: expected an automatic call entry; actual bare `fail` |
| `quod_lobby_tests:failed_hosting_selector_is_not_inactive_test_` | 1 failed: same `no_solution` operation/indicator, now with inner `[]` |

Thus all 77 checks in the seven network/history/receipt modules passed without
relaxing any assertion. Together with exact leaked PIDs/anchor evidence, this
separates their full-run failures from a semantic need for automatic reasons.
The two isolated failures are additional explicit entries in the implementation
checklist; the full-run trace fixture had stopped at identity setup instead.
These follow-ups do not erase or replace any of the original 341 failures.

## Scene measurements

The [first probe](scenes-01.log) was deliberately stopped, exit 1, while its
optional `erts_debug:size/1` inspection consumed a CPU after the proof had
finished. The [stop marker](scenes-01-stop.md),
[VM function evidence](scenes-01-diagnostic.txt) and
[instrumentation change](scenes-01-instrumentation.patch) are retained. No time
from that probe is used. It was observation overhead, not Prolog proof work.

The corrected [scenes-02 probe](scenes-02.log) exited 0. OTP 28, eight online
schedulers, fresh VM per case, one observation per case. The
[host process sample](scene-load-01.log) confirmed the game and VR processes
were absent. Deep goal dereferencing is still unchanged.

| Marks | Valid seconds | Refused seconds | Valid held process MiB | Refused held process bytes |
| --- | ---: | ---: | ---: | ---: |
| 300 | 0.461 | 0.348 | 68.0 | 13,808 |
| 600 | 1.358 | 0.984 | 292.4 | 13,808 |
| 1200 | 4.527 | 2.793 | 1047.7 | 13,808 |

All six cases kept zero reasons. [scenes.json](scenes.json) preserves exact
seconds and bytes, including the separate before-GC memory samples. Held memory
is `process_info(memory)` after GC with the full result reachable; it includes
allocated process heap, and excludes ETS/VM-wide allocations. It is not peak
memory or a graph-word count. Do not directly equate it to an older probe's
unspecified memory sample.

The actual rendering EUnit test passed in **2.407 seconds**, under its unchanged
five-second limit. This focused case provides its elapsed time, which the full
suite's compact output did not show; it is not a retry of a failed rendering test.
The native host-marker check also passed: ordinary duplicate explicit reasons
are retained, while the existing reserved marker appears once locally and in
remote merge.

The semantic change fixes excessive reason output and improves the rendering
test's margin, but a valid 1200-mark proof still retains 1,098,557,560 process
bytes. The plan therefore recommends unchanged-term sharing as a separate
implementation/verification phase before the same release. That phase is not
implemented or measured by this experiment, and no linear-time claim is made.

## Verified consumer findings

The [implementation plan](../../../nimbalyst-local/plans/explicit-failure-reasons.md)
contains the full per-file treatment and proposed spec text.

- Atomic votes do not need an invented fallback. Failed proofs do not seal;
  commit validation explicitly creates the nonempty refusal list. Preserve
  atomic/outcome/terminal validation. The original handoff's contrary premise
  is corrected in the plan.
- The effect journal's `desired_state/3` handles `{fail,_}` as absence but
  mistakenly treats bare `fail` as unavailable. Plan a fix in that existing
  consumer, with lifecycle regression coverage. Do not make facts state reasons
  to work around the journal.
- The refound operator assumes a tagged failure for an absent administrator
  fact. Plan its bare-failure assertion update. Four fleet-verifier checks
  compare against `{fail,[]}` and already accept failures/errors as success;
  plan positive answer checks.
- Root catalog, directory peer validation and node-actor identity validation
  already handle both public failure forms. Internal proof-session consumers
  receive `{fail,Reasons}`, including `[]`, and do not need a new result path.
- Runtime and GUI wrappers retain their operation and permit an empty inner
  reason list. The client result codec, explorer and signed read envelopes
  already permit empty reasons or plain failure. Browser and Godot clients
  dispatch on the result class.
- There are 79 explicit `fail_with_reason` occurrences in 12 ontology files,
  and no `get_fail_reasons` use in checked-in production ontologies. Existing
  explicit reasons stay. Schema recognition/search failures remain ordinary.
- Preserve the existing reserved `fail_reasons_truncated` marker contract if
  retaining the independent host admission API. It is not an ordinary reason
  atom with duplicate-preservation semantics. The erlog guide still describes
  automatic entries and obsolete quotas; its replacement belongs in the plan.

## Consensus and review

GPT Sol independently checked the plan and source. Its findings above are
included in the draft. Its final pass found no further blocker to plan
approval after correcting the spec text to say **refused** Votes require
nonempty reasons. Prepared Votes and successful commit outcomes retain their
existing `none` form. It did not run suites or edit source.

Stored record/codec shapes do not need a format change, but proof semantics
change. Policy can inspect reasons, and projection rebuild revalidates signed
and prepared authorization at historical parents. Coordinate the fleet engine
version. Keeping ledgers requires candidate replay of actual retained certified
histories, including foreign projections; current-source search cannot prove
historical safety. Refound is a separately authorized greenfield alternative.

## Evidence handling and cleanup

[redactions.json](redactions.json) records the original and redacted SHA-256
for each affected log, with counts. Only 175 generated private-key octet strings
in 77 EUnit/CT log files were replaced; public keys, results, failure diagnostics
and every line number remain. Test private data under CT's `log_private` was
not retained. No active account or deployed key was read for this experiment.

[cleanup.json](cleanup.json) records removal of the 610 MiB disposable build
tree and 115 failed hosted-agent fixture directories whose exact paths were
emitted by this run. Unrelated temporary directories were not globbed or
deleted. The stopped probe's heap dump was removed with the build tree after
extracting its function evidence. All gate exits, failure logs and stop markers
remain here.

Actual product delta for this planning task: **zero production, test, spec or
pin lines changed** in either source checkout. The new lines are the plan,
measurement tools and reviewable evidence required for the decision. No commit,
push, version bump or deployment was performed. The plan and this report remain
uncommitted pending Yan's approval.

[Final checks](verification.json) confirm unchanged source checkouts, complete
failure inventories, preserved log line links, redaction and cleanup.
[Artifact hashes](artifacts.json) identify the retained tools, plan and evidence.

## Limits of this evidence

This is the automatic-recording deletion experiment only. It does not test a
production patch, changed ontology rules, fixed effect-journal handling,
corrected test expectations, a new dependency pin, full clean server gates or
a deployment. The legacy QuickCheck properties remain unrun. No commit, push,
label change, refound or release is authorized by these results.
