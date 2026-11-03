# Durable predicate definition removal

The bounded Stage 2 continuation is implemented in `pearl-stone`, based on Quod
`b30967e33bb8d64eca3f8a093bad018549c9b8af`. Changes remain uncommitted. All required bounded obligations have passing evidence;
the final normal production compile also passes.
Erlog remains pinned to locally available, unpublished
`79b3874617a4eb9f76d5089a3fc908667e605e8a`. Its source/configuration was not edited.
The inherited generated `ebin/erlog.app` modification is outside this change.
No user store or Godot file was changed by this continuation.

`work_radar(tsk_01M5PY8TEXKG858WBZJ1RHC6EW)` returned no matching issue. No duplicate
was created. The existing plan was resolved and linked to this session.

## Cause and correction

The real signed baseline, `baseline03`, committed `transaction(abolish(likes/2))`
but still found `likes/2` through `current_predicate/1`. Its literal assertion
failure is retained in [stdout](logs/baseline03-stdout.log), with exact inputs,
command, exit 1 and both EOFs in the [receipt](inputs/baseline03.json).

The trace followed the existing owners:

1. [quod_erlog_db_local_prove](../../../src/quod_erlog_db_local_prove.erl) already
   marked the proof-local definition abolished, but `functor_ops` sealed only
   clause retractions. Empty definitions produced no durable removal at all.
2. Sealing now retains the existing exact clause retractions and appends
   `{abolish,{Name,Arity}}` before any surviving assertions. Definition intent
   contributes to existing ordinary/atomic/independent provenance, even when
   there are no clauses. Savepoints, cut and rollback machinery are unchanged.
3. [quod_diff](../../../src/quod_diff.erl) validates and applies that operation
   using the existing `abolish_clauses` MVCC callback. Undefined/static definitions
   produce no applied removal. Existing policy and immutable-manifest checks use
   the shared mutation predicate. The committee scans now use it too, for the
   actual `peer_admitted/4` definition.
4. [quod_dtx](../../../src/quod_dtx.erl) includes an abolished definition in the
   existing signed write-conflict descriptor. Its read token, transaction
   validation, atomic reservation and committed-policy authorization remain in
   their existing owners. A concurrent write refuses the original attempted
   removal with `conflict_retry`; it is not resubmitted.
5. Ordinary content, foreign application and atomic resolution carry the same
   diff through existing transaction encoding, ledger recording and
   [committed projection](../../../src/quod_committed_projection.erl). Recovery
   applies the recorded operation and preserves lookup of the original request;
   it does not rerun the goal. Retaining preceding retracts preserves existing
   fact reactions and changed-head notices.
6. Existing MVCC changed-functor publication and installed-view dependency
   notices invalidate consumers. The ordinary source-authorized predicate
   catalogue then omits the definition. The reflected predicate class no longer
   supplies the selected source recipe, so the existing
   [view owner](../../../src/quod_client_view.erl) withdraws it. There is no
   production view/client change, registry, new tombstone scheme or persistence
   mechanism.

The [production patch](production.patch) is **+40/-21, net +19 lines in seven
files**, including comment changes and one conditional `TEST` export needed by
an existing fixture. Growth represents the missing durable operation, its intent
and conflict accounting, guards and explorer rendering; duplicate committee
scans were removed. No hardcoded limit was introduced or raised.

The [multiwrite contract](../../multiwrite-architecture.md#predicate-definition-removal)
and [space contract](../../spaces.md#reflected-ontology-contents) describe current
behavior. Deletion/recreation presentation identity and individually selectable
clauses remain undecided. No ruling on them was needed for this correction.
Existing operation encodings remain unchanged, but older binaries do not accept
the new operation. No deployment, history rewrite or migration is authorized.

## Verified obligations

- `signed06` verifies successful signed removal, last-clause retraction retaining
  an empty definition, abolition of that empty definition, an unaffected
  predicate, cut/failure rollback, ordinary-origin and foreign-ledger restart,
  and exact original-operation recovery. The original signed requests are read
  for recovery, never replayed. The absence/unaffected repeats have zero watched
  work through real owners.
- `corrections08` verifies denied signed removal, two-target rollback, an actual
  concurrent-write conflict, two-target atomic commit and recovery, together
  with original-operation lookup. The empty-definition unit case additionally
  checks the write-conflict key, canonical wire roundtrip, malformed-operation
  refusal and unchanged repeated application.
- `withdrawal05` and `signed06` verify actual signed world/editor subscriptions:
  installed editor before removal, owner refreshes after commit, displayed
  occurrence absent afterward, stale selected source Eidolon unavailable,
  unaffected member retained, and empty-defined member retained until abolished.
  Repeated editor renewals retain the same dependency monitors; repeated live
  and missing-selection checks produce zero watched history/rebuild/write/sync
  calls. The source-access/catalogue path is used by the ordinary reflected
  instance and recipe; ontology-wide source permission itself is not revoked.
- `reaction09` verifies signed definition removal still delivers its existing
  retract reaction exactly once. A subsequent processed barrier event establishes
  delivery evidence, with expected reaction count and no sleeps.
- `candidate01` passed 71 checks across diff, overlay, independent provenance,
  transaction predicates and the new empty-definition unit. Its two fixture
  expectation failures were corrected separately. `guards07` passed 88 checks
  covering DTX, commit validation, material policy and committee shape. Its two
  failing checks passed in `corrections08` after the recorded corrections.

The no-work assertions use the existing delivered trace/barrier helper in
[quod_lobby_tests](../../../test/quod_lobby_tests.erl): projection creation/source
loading/application, MVCC creation, ledger folds/reads/snapshots/history views,
DETS inserts/syncs and file writes/pwrites/write_file/sync/datasync. These are
zero watched calls, not a claim of zero computation. Real updates are separately
observed through subscription delivery and changed signed answers.

The authored test gallery contains three ordinary reflected members, deriving
membership from the ontology's real catalogue. This is a disposable fixture, not
production filtering, a display cap or a replacement for large-catalogue
acceptance. Full large-catalogue acceptance remains credited to the prior
configured aggregate campaign and matching installed functional source. It was
not repeated here. No native/hardware test is claimed.

## Literal failures and their disposition

Every run has complete stdout/stderr, true child exit and EOFs. A failed run is
never relabelled as passing. The following are separate invocations:

| Label | Result | Disposition |
| --- | --- | --- |
| baseline01 | exit 1, compile failure | Inherited container dependency symlinks were unusable on the host; explicit host dependency paths used next. |
| baseline02 | exit 1, setup cancelled | Fixture copied its own beam onto itself when test/production ebins coincided; separate test ebin used next. |
| baseline03 | exit 1, 1 real failure | Committed signed abolish left the predicate defined. This is the causal baseline. |
| candidate01 | exit 1, 71 pass/2 fail | Recovery returned the correct foreign completion vector and conflict returned exact `conflict_retry`; fixtures expected wrong result shapes. Assertions changed to those exact contracts. |
| signed02 | exit 1, 3 pass/1 fail | Signed removal cases passed. View fixture lacked its rendering vocabulary pin and returned an empty projection. |
| withdrawal03 | exit 1, 1 fail | After supplying the vocabulary pin, full catalogue missed the existing 10-second observation window. No claim that one cause explains the timeout. |
| withdrawal04 | exit 1, compile failure | Gallery comprehension syntax error. Corrected in the next separate run. |
| withdrawal05 | exit 0, 1 pass | Bounded authored gallery and selected-editor lifecycle passed. |
| signed06 | exit 1, 8 pass/2 fail | Origin/foreign recovery and view withdrawal passed. Additional illegal committee request returned pending; reaction test's signed hosting setup was denied. |
| guards07 | exit 1, 88 pass/2 fail | Existing DTX fixture called a nonexported test helper; new explorer expectation used functional rather than the existing infix formatter. |
| corrections08 | exit 1, 3 pass/1 fail | Signed denial/atomic/conflict, DTX fixture and explorer passed. Reaction arrived correctly; its local absence assertion expected `{fail,_}` but the API returned `fail`. |
| reaction09 | exit 0, 1 pass | Correct exact local absence result; signed removal and reaction/barrier counts passed. |
| production10 | exit 0, compile pass | All production Erlang modules compiled without `TEST` or `export_all`; configured Erlog rebuilt. |

The extra `signed06` committee probe was an invalid whole-committee proposal,
not an ACL-denied `likes/2` removal. The existing acceptance gate rejects both
mass clause removal and definition removal; it does not promise a synchronous
terminal failure reply for that invalid shape. The test's added terminal-reply
expectation was removed; the still-valid membership-safety obligation is checked
at `transaction_shape_gate_test` and `membership_diff_acceptable`, using the real
`peer_admitted/4` arity. Its pending result is preserved, was not resubmitted, and
is not counted as terminal-denial acceptance. That broader endpoint behavior was
not changed. The failed disposable store was retained. Required signed ACL denial
is covered by the locked `likes/2` ontology in `corrections08`.

Independent source review caught an initial arity-5 mistake in the new committee
scan after `withdrawal05`; it was corrected to arity 4 before `signed06` and the
committee gates. Earlier snapshots remain literal. Reaction fixture setup now
uses the established hosting helper; the operation under test is still signed.
The existing DTX fixture now has its explicit `TEST` export rather than relying
on blanket `export_all`. No production behavior or assertion was weakened for
that fixture.

## Reproduction and source provenance

[run.py](run.py) snapshots source and configured Erlog into a fresh labelled
runtime, compiles it, runs the selected checks sequentially, drains both child
streams to EOF and records the actual exit. It refuses to overwrite an existing
label. Run from the worktree, for example:

```sh
python3 doc/evidence/stage2-predicate-removal-20261103/run.py fresh-label quod_predicate_removal_tests
```

It uses the existing qualified runtime directory for native/application assets
and the existing dependency checkout for pinned source and dependency ebins.
From `withdrawal03`, Erlog is explicitly recompiled using its configuration
script and maps bindings are asserted. Earlier runs used the qualified copied
Erlog beams; their receipts do not retroactively claim an explicit rebuild.
From `withdrawal04`, Quod uses explicit `TEST` exports without `export_all`.
Per-label driver copies begin at `withdrawal03`; earlier exact child commands and
source hashes remain in their receipts.

The [final source manifest](inputs/final-source.json) lists exact current hashes,
run receipt/log hashes and production delta. Per-run JSON receipts hold source
hashes and the complete command; later receipts also hold compiled-input lists
and runtime beam hashes. Labelled source copies remain in the worktree build
area. `corrections08` and `reaction09` have exactly the final production source.
The `signed06` to final deltas are two comments and the conditional test export;
`guards07` differs only by that export. Those exact diffs are retained alongside
the receipts. No already-passing behavioral suite was repeated for a new green
summary.

Stage 2 remains in development for its separate outstanding policy-owner work.
Stage 3 terrain, broader renewal optimization, founding, package/release,
deployment, user-store cleanup/migration, hardware/shutdown and external reviews
were outside this continuation.
