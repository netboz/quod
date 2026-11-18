# Explicit failure reasons implementation

Implementation authorized by Yan on 2026-11-18 after plan and independent review.
Base Quod a55a3f0889d269ba48fd864ded281ea6799deb51;
base erlog 79b3874617a4eb9f76d5089a3fc908667e605e8a.

Development checks use the visible `_checkouts/erlog` symlink to the authoritative
`/home/yan/src/erlog` fork. This is not release pin evidence. The exact commit
pin and final release verification require the separately approved engine commit.

## Explicit-only phase

- erlog-explicit-01: 123 tests pass, including both original record properties
  at 100 generated cases each. Replaced the unavailable EQC harness with
  test-only PropEr 1.5.0; preserved property bodies and assertions.
- focused-explicit-01: 215 tests, 30 failures. Newly reached lifecycle cases
  retained old automatic-reason expectations. One added regression used the
  wrong target tuple index; corrected from 8 to 9. No production defect inferred
  from that test error.
- focused-explicit-02: 215 tests, 6 failures. Five old ordinary-failure
  expectations; one overbroad test update incorrectly expected bare failure
  where the installed ACL explicitly refuses. Corrected to exact not_allowed.
- Each follow-up has a distinct label; all failed logs remain.

The existing lifecycle fixture now cleans its owners if initialization fails
before returning the fixture. The journal handles bare fail as logical absence;
real unavailable/error results retain their separate classification.

Implementation and development validation are complete. The engine is committed
as `5dad08cdc95f5100f8885caa65038b0c6ee832f9`. The engine was pushed after separate approval. Yan subsequently approved the
validated Quod commit and push. This bundle records the pre-commit verification
boundary; the resulting Quod commit identity is recorded in the session/tracker.
No version bump, refound or deployment has been performed.

## Subsequent checks

- focused-explicit-03: 215 tests, 3 failures, all later lifecycle assertions
  expecting automatic reasons; updated those expectations. All core proof,
  ask, rollback and trace tests passed before applying the sharing phase.
- erlog-sharing-01: 128 tests, one new test incorrectly expected dderef_list
  to accept an unbound list tail. Kept its existing instantiation error and
  added a proper-tail case. No interpreter correction was needed.
- erlog-sharing-02: 128 tests pass, including 200 generated record checks.
- combined-eunit-01: 50 tests, one old absent-key expectation and six
  cancellations. The TLS listener failed with eperm inside the sandbox;
  corrected the expectation and labelled the unsandboxed follow-up separately.

- combined-eunit-02: 4,370 tests, 126 failures, no cancellations. Full run
  completed in 866.777 seconds. The failures expose further ordinary-failure
  expectations, a signed-read helper missing its bare-failure clause, and
  generic negative-test helpers that assumed encoded reasons. Four earlier
  expectation edits were too broad: restored explicit ACL checks and split
  menu refusals into exact authored reasons versus ordinary recognizer failure.
  The account scenario reached its personal-operation negative helper; its
  bare result was rejected by that helper rather than by production recovery.
  Each correction is followed by a separately labelled focused run.

Generic negative helpers used by both ACL refusals and ordinary false goals
now distinguish both logical results from success and infrastructure errors.
Checks for specific reasons still decode and assert those reasons; direct
missing-fact and recognizer assertions expect bare failure exactly.

- helpers-eunit-01: 204 tests, 16 failures. The lifecycle module, including
  all account/recovery scenarios and the new duplicate-effect/no-I/O checks,
  passes. Remaining failures are later ordinary-failure assertions in GUI,
  lobby and permission fixtures. Updated the fixture-owner recognizers and
  absent/rolled-back facts while retaining other principals' ACL checks.

- helpers-eunit-02: 94 tests, 3 failures. Two checks need explicit target-ACL
  refusal restored after their ordinary domain-policy checks; now assert exact
  not_allowed targets. One later signing check correctly returns bare failure
  for a revoked/mismatched key. The other 91 cases pass.

- remaining-eunit-01: 85 tests, 16 failures. Further absent facts and signed
  false results, plus the stage-one GUI read helper's missing bare-failure
  clause. The predicate-removal fixture used one helper for ordinary rollback
  and target ACL denial; split the latter into an exact not_allowed check.
  Signing-policy denials remain bare failure through authorization_result;
  their custody and policy-boundary assertions are unchanged.

- remaining-eunit-02: 18 tests, 2 failures. Both reach the same node-delegation
  helper's later ungranted-goal assertion. Updated that ordinary refusal and
  the same policy's withdrawn-grant assertion. The other 16 cases pass.

- remaining-eunit-03: both node-delegation cases pass. Every failed EUnit case
  from combined-eunit-02 has now passed a labelled follow-up after correction.
  This is not yet a claim that the complete clean suite passes together.

- focused-ct-01: 77 cases, 71 pass and 6 fail. Wrong-anchor join now returns
  ordinary fail; that assertion prevented saved configuration reaching the
  next ordered join case. Three failover cases reach revoked-key fencing,
  which correctly retains an explicit not_allowed reason; restored its exact
  target check. The selected observer's internal native_read API retains
  {fail, []}, unlike the public prove_ro reply; restored that exact assertion.
  All remote explicit-reason, deep-list, structural-depth, rollback and root
  effect cases pass. Growth passes all nine cases.

- focused-ct-02: all 10 join/failover cases pass after the exact expectation
  corrections. native-read-ct-01: the selected-observer case passes with its
  existing internal {fail, []} contract.


## Independent source review

Reviewed the candidate interpreter traversal, diagnostic admission and dispatch,
journal consumer, local/remote failure propagation, signed negative-test helpers,
and atomic terminal validation. No additional production correction was found.

- Removed automatic diagnostic choice points have no remaining production
  callers or alternate implementation. Explicit insertion/merge and native
  unlimited admission remain under the existing interpreter owner.
- Dereferencing returns unchanged immutable subtrees and rebuilds only paths
  containing resolved variables. It resolves against the current bindings on
  every invocation; no cache, preliminary groundness pass or production
  `erts_debug` call was added. Tests cover physical sharing, variable chains,
  opaque symbols, list tails, tuple positions, host dispatch, backtracking and cut.
- The journal classifies both logical failure forms as absent, preserving
  unavailable owners and incompatible target identities. Existing false
  postcondition coverage remains; the added duplicate-effect path checks actual
  journal processing and verifies zero re-execution, projection/history work,
  writes or syncs after completion.
- Named ACL/domain refusals still assert explicit reasons. Mixed negative-test
  helpers accept only the two logical failure classes, not success or errors.
  No deadline, timeout, consensus, custody or terminal non-empty-reason check was
  relaxed. The failover waiter retains its subscription and absolute deadline.
- Production source delta is Quod +2/-1 and erlog +45/-63: **17 fewer lines**.
  Test growth adds sharing and journal regressions and stronger exact-reason
  assertions; test-only PropEr makes the existing record properties runnable.

`candidate-01-manifest.json` freezes both repository bases and source hashes;
`candidate-01-quod.patch` and `candidate-01-erlog.patch` reconstruct the changes,
including new source tools/tests. The visible local engine override is recorded.
The server gates validate this development candidate, not a committed dependency
pin. Engine commit/push, exact pin, final pinned verification, Quod commit/push,
version and coordinated deployment remain separately authorized steps.


## Clean combined candidate gates

`server-01` uses the frozen candidate and the standard sequential runner.
Both clean steps exited zero. EUnit passed **4,370 tests, zero failures**, in
971.662 seconds. The full child log and exit are retained. Common Test passed **150 cases**;
xref and Dialyzer both exited zero. All six sequential gate steps passed.


The post-gate source check found one build-tool change: rebar removed only the
erlog lock entry while using the visible local checkout. Retained the exact
change and effective lock as `server-01-lock-side-effect.patch` and
`server-01-effective-rebar.lock`, then restored the frozen original lock after
verifying its hash against the manifest. All other frozen files and both HEADs
were unchanged. The checkout selected the engine throughout, so this does not
change which interpreter the development gates exercised. It remains a reason
not to claim final pinned-release verification.


## Matched scene measurements

Both labelled measurement runs exited zero: **72 samples**, all with the expected
verdict and zero retained reasons. The rendering EUnit case passed in
**1.556 seconds**, under its unchanged five-second limit. All scene timing
samples ran after the server gates; profiling samples ran in separate fresh VMs.
Each case uses three fresh proofs over the same immutable committed test state.
The refused case prepends a duplicate to the stated number of marks.

Values below are medians of three samples. MB means 1,000,000 bytes; allocations
are millions of machine words attributed by OTP 28 tprof to the proof process.

| Scene | Marks | Baseline seconds | Sharing seconds | Baseline held MB | Sharing held MB | Baseline allocated Mwords | Sharing allocated Mwords |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| valid | 300 | 0.445 | 0.314 | 85.564 | 16.584 | 111.526 | 76.246 |
| valid | 600 | 1.374 | 0.777 | 306.588 | 34.387 | 290.698 | 152.498 |
| valid | 1200 | 4.512 | 2.160 | 1098.558 | 71.303 | 851.645 | 304.949 |
| refused | 300 | 0.344 | 0.270 | 0.089 | 0.089 | 94.081 | 75.727 |
| refused | 600 | 0.944 | 0.601 | 0.231 | 0.231 | 221.767 | 151.206 |
| refused | 1200 | 3.009 | 1.493 | 0.372 | 0.372 | 578.538 | 302.105 |

At 1,200 valid marks, median time is **52.1% lower**, held
process memory **93.5% lower**, and measured allocation
**64.2% lower**. Sharing substantially reduces copying,
but the proof still traverses its terms and is not a linear-time scene algorithm.

[Raw samples](scenes.json), [CSV](scenes.csv) and [grouped statistics](scene-summary.json)
retain every first and repeated result, reductions and allocation count.
Timing statistics use only unprofiled samples. tprof elapsed times are observer-
affected and are not used for speed comparisons. Held memory is process memory
after full GC with the result reachable, including allocated heaps; it is not
peak memory, live graph size, ETS memory or VM-wide usage. This repeated-proof
probe also keeps the reusable input and initial state reachable, so refused-case
held memory must not be directly equated with the older single-use probe.
The engine paths, OTP version and scheduler count are logged for each fresh VM;
host activity is retained before and after the campaign.


## Evidence handling and final review boundary

Retained only this campaign's four Common Test run directories, excluding
`log_private` runtime ledgers and generated identities. All case/suite logs and
all failed labelled attempts remain. Redacted 306 generated test private-key
values while preserving line counts. The final scan caught one quoted-binary
rendering missed by the numeric-only first pass; the release redactor now handles
numeric, quoted, mixed and HTML forms. Six representation checks preserve public
fields and line counts. Both redaction receipts are retained; the follow-up
secret-pattern scan is clear.

The redactor correction is the only source change after `candidate-01` server
gates and scene measurements. `candidate-02` freezes that evidence-tool correction
separately; runtime sources, test sources and both repository HEADs are unchanged.
The user's pre-existing untracked engine lock/scanner files were preserved; the
clean build regenerated only scanner source-path attributes, which were restored
byte-for-byte and hash-verified after verification.


Removed this campaign's four disposable CT run trees and three scene build
folders after retaining logs, source/beam hashes and measurements. Preserved all
43 pre-existing CT run directories. The original experiment's retained artifacts
remain hash-identical. The cleanup receipt lists every removed build path.

The implementation is ready for the engine commit decision. The remaining
release work is explicit: commit/push the reviewed erlog change, replace Quod's
exact dependency pin and remove the development override, validate that pinned
tree, then obtain Quod commit/push, version and coordinated deployment authority.
No retained-history replay or refound has been performed. The approved plan
remains unfinished for those steps; the local tracker is in review.


The engine commit proposal was submitted through the required Nimbalyst widget,
which rejected it because `/home/yan/src/erlog` is outside this session's attached
repositories. No commit or staging occurred; the original engine HEAD and empty
index were verified. Attach the existing engine checkout to this workspace, or
submit the reviewed proposal from a session opened in that checkout. The current
blocker is editor repository scope, not a failed test or an approval-review denial.


## Engine commit and prepared pin

Yan attached the existing engine checkout. The Nimbalyst commit proposal then
committed all eight reviewed engine files as
`5dad08cdc95f5100f8885caa65038b0c6ee832f9`, resolving the editor-scope blocker.
The source hash check passed immediately before the proposal. Both Quod pin files
now name that exact SHA. The remote `quod` branch was verified at the parent
`79b3874617a4eb9f76d5089a3fc908667e605e8a`; the proposed push adds one commit.
The development checkout override remains until the remote commit is available
for the final pinned build. Engine push approval and that validation are pending.


Yan approved publishing the engine commit and validating the exact pin. The
one-commit push to `netboz/erlog:quod` succeeded. Quod fetched that SHA, and all
56 tracked files in the dependency matched the committed engine. The override
and checkout beam caches are removed; rebar recreated 24 stale test dependency
links against this checkout. The [published-pin validation](pinned/report.md)
records the separate clean gate campaign on `candidate-03`.


## Final published-pin review

The published dependency passed the complete clean sequential gates: 4,370
EUnit tests, 150 Common Test cases, xref and Dialyzer. All 36 final scene samples
passed; the rendering case took 1.700 seconds under its unchanged five-second
limit. Valid 1,200-mark median time was 2.345937 seconds and held process memory
71,303,368 bytes. This independent qualification uses the normal dependency
path; the earlier matched comparison remains separately labelled.

The source/lock manifest remained unchanged throughout the final gates. The
committed engine's authored sources match the fetched dependency. The only
source changes after the earlier development qualification are the reviewed
exact pin, a spec evidence link, and the separately checked evidence redactor.
The current Quod change is ready for its separate commit/push decision. Version
changes, actual-history replay, refound and deployment remain separate steps.


Yan approved the Quod commit and its normal fast-forward push separately in the
final decision widget. All reviewed source and evidence hashes were rechecked
before recording that approval. The commit includes the complete evidence and
unfinished release plan. Version, history-retention/refound and deployment
choices remain unapproved; this code publication does not authorize those steps.
