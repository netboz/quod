# Development receipts

These incremental checks reuse the dependency/native build cache from the retained M0 campaign06 in a separate development directory, `/tmp/quod-m1a-dev-01`. They are not clean release gates and do not replace final frozen-source qualification. M0 stages and evidence are unchanged.

The initial HEAD is `d027f9f65bbce2f484f906c92bf07ebaa4669c38`, parent `f6c29fe925e666dd68ee7fa68c0e03f5d03391a2`. Yan committed the M0 prerequisite immediately before this worker started. The 778 archived source entries and original tracked patch matched the verified M0 snapshot; see the input comparison. No worker commit, reset, integration branch or main import occurred.

The first development preparation attempted copying cached native files and then an ignored generated NIF. Host errors were `PermissionError: [Errno 13] Permission denied` on root-owned cached `.lock`/native output files. The copier now selects authored tracked/untracked inputs, separately labeling reused compiled cache. These preparation errors occurred before a child test receipt could be written.

- `focused-foundations-01` and `02`: compiler error from unbound fixture variables. The second attempt copied no corrected test because preparation failed on an ignored NIF. Both receipts remain; neither ran tests.
- `03`–`05`: signup returned `proof_unavailable`. The first diagnostic used the calling process as tracer and supplied no useful raw error. No accepted write was resent.
- `06`: the separate collector exposed `instantiation_error`: creation policy must bind the supplied options before deriving its token. The policy ordering was corrected.
- `07`: exposed `{too_large,answer}` for the approximately 95,803-byte private source-buffer recipe. This is the existing 64-KiB proof-answer encoding bound. The implementation preserves that bound and instead extends existing source-file preparation with a hash-checked descriptor; no transaction split or budget increase.
- `08`: custody preparation was incorrectly invoked during the write proof. It now remains an explicit preceding authorized read; setup rechecks inputs and the existing assignment action owns custody enforcement.
- `09`: committed policy called native identity lookup. Its callbacks now use authenticated operation references and committed local facts.
- `10`: fixture attempted formatting an anonymous variable incorrectly during the controller key read. It now calls the existing `personal_agent/2` query.
- `11`: passed its initial integrated seven-foundation/two-user/signup/setup/basic privacy/Save/owner-restart scope. This is not full M1a acceptance.
- `guarded-source-01`: matching/mismatched hash, malformed descriptor, original byte parser semantics and preparation-once passed.
- `guarded-source-02`: Docker socket access denied before test startup. No tests ran. Subsequent Docker checks use the authorized escalated tool route.
- `guarded-source-03`: passed after preserving the existing configured relative consult-path lookup.
- `focused-foundations-12`: explicitly interrupted because two development commands shared the same build directory. Docker's SIGTERM produced child exit 0; **this is not a passing test**. Its log contains no EUnit result.
- `13`: GUI harness called a physics socket inspection helper on a GUI socket; the harness was corrected.
- `14`: reused an older test beam despite corrected staged source because preserved source timestamps preceded the prior beam's build. This is invalid evidence for the new assertions. The runner now removes only its own application/test beams before compilation and prunes retired ontology sources from its stage.
- `15`: host permission failure removing root-owned development beams, before Docker/test startup. Removal now runs in the disposable builder and is included in the exact command receipt.
- `16`: expected a durable target receipt for a failed operation; no such commit exists. The harness now waits for completion only when the production response reports committed.
- `17`: controller/retained-view checks and HTTPS public source/privacy reads reached the client operation. The harness waited on the human's signed read instruction instead of the enclosed A execute operation. The barrier now extracts the exact original A request and awaits that owner. No uncertain write was resubmitted.

Every new attempt has a distinct label. Original failures and manifests remain. Random disposable fixture keys in supervisor crash reports must be removed from exportable logs before final snapshot; full originals will be retained privately outside the source archive with explicit redaction hashes. Public founding/endpoint receipts contain no seed or unlock bytes.

Post-review key regression: wrong-key-01 failed before setup because the new
unrelated-agent founding fixture passed a non-ground clause in terms/1. Removed
that unnecessary grant. wrong-key-02 used an invalid EUnit generator suffix and
cancelled without executing. wrong-key-03 used the correct invocation and
reproduced a committed setup for an arbitrary supplied key. All labels retained.
The receipt correction and its tests are subsequent source, not covered by those
failed runs or by the Fable snapshot.

Post-review continued qualification:

- `custody-receipt-01`: 16 vault tests pass, including immutable receipt checks
  without a live vault, tampering, executor/history isolation, and unchanged
  prior custody obligations. The later context/output validation cleanup is
  additionally covered by `custody-and-parts-01`.
- `custody-and-parts-01`: 26 tests pass. Both local and explicitly selected
  foreign storage admit their own existing occupant; injected inherited
  constructor failure rolls back classification/assignment/admission. An
  imported cross-history occupant refuses explicitly. Empty creation is retained.
- `focused-foundations-22`: signed setup refusals, privacy/controller and HTTPS
  client portions passed, then a new foundation-height assertion failed (GUI5,
  controllers1, space9 vs initial1). Atomic read participants legitimately append
  control records. The corrected privacy assertion compares complete stored
  source before and after private operations, preserving the no-private-copy
  obligation instead of incorrectly equating ledger height with domain state.
- `semantic-owners-01`: 96 tests, six failures. The model fixture loaded the
  merged scene/model source a second time, yielding duplicate answers. Lens
  fixtures referenced the old namespace and pre-merge limit selector. Two GUI
  fixtures tried to install the complete user composition through a signed edit
  exceeding the existing encoding bound; they now compose it once at genesis.
  A third declared a second HUD allowance alongside the template default and
  correctly failed the single-answer policy. Its authored fixture limit now
  replaces that default at genesis. Assertions, deadline/budget limits and
  production execution paths are preserved. Later receipt is separately labeled.
- `browser-accounts-02`: no child started; the explicitly guessed Node binary
  did not exist. Its launch failure record is retained. `browser-accounts-03`
  uses PATH Node as in the original receipt and passes all nine tests.
- `browser-tests-03` passes all 30 client test files; `browser-build-03` passes
  TypeScript/Vite and refreshes packaged assets after the account changes.

Tracker review update preparation02 failed locally on a missing description key;
its absent @FILE prevented any API mutation (ENOENT). The tracker_get response
provides the full body in its summary after the metadata separator. Update03
used that exact current body plus review dispositions. Its outer isError false
was initially mistaken for complete success. The later response audit below
corrects that claim: collaborative storage failed despite the local body save.

- `semantic-owners-02`: 96 tests, one failure. The native presentation fixture's
  remaining post-genesis human classification went through ordinary creation
  semantics and refused. That human is now an explicit inert genesis fact,
  alongside the same authored two-question allowance; the native presentation
  assertions do not depend on constructing a human.
- `semantic-owners-03`: native/deferred question tests pass. Three lobby/source
  cases failed. A worker cleanup incorrectly classified `public_source_query/1`
  as unused after searching only the composed GUI files; its definition belongs
  to common_predicates.pl. The shared selector was restored. Its narrow public
  vocabulary admission remains distinct from complete-source policy. Also, the
  old separate rendering/model editing targets both map to GUI now; the duplicate
  target was removed and the wrapper-withdrawal case uses a separate predicate,
  preserving both refusal and original committed-edit recovery assertions.

The later focused qualification and clean source manifests cover those fixes.
No additional Claude consultation was launched; post-review fixes are independently
checked. The GUI owner now declares the shared eidolon class once; component
sources retain their specific subclasses. Empty selector delegates were removed
only after checking common/runtime definitions as well as the composed files.

- `inspection-owners-01`: three tests, one failure. The old wrapper withdrawal
  fixture asked its now-local GUI owner; local asks reuse their admitted scope
  and do not re-enter a foreign ACL. The fixture now targets the node foundation.
  Independent checking then exposed a real Root-denied self-source fallback.
- `inspection-withdrawal-01`: fixture compiler error (`Gui=<<` tokenization),
  before execution. `inspection-withdrawal-02` reproduces the real fallback:
  Root denial yielded valid empty raw source. No failure was relabeled a pass.
- `inspection-owners-02`: four tests pass after the source inspection owner
  requires Root's grant for its own source and permits the ordinary fallback only
  through a foreign target's admission. No runtime ACL bypass is added.
- `focused-foundations-23`: the expanded integrated journey passes, including
  two humans, independent unrelated agent, private write and wrong-history
  refusals, final acknowledgement rollback, revocation and original-key restart.
  The later three rollback assertions and inspection correction require the
  clean campaign. `public-receipt-01` separately verifies both retained custody
  signatures offline using the existing production parser/codec/crypto.

Clean campaign `gates-01` uses a new empty stage, exact qualified dependency
sources and no compiled inputs. Its full EUnit has emitted failure markers while
running; the detailed completed result is required before diagnosis or rerun.
No subsequent gate is credited at this point. The native locked gate passed.

Campaign01 finished 4,251 EUnit tests with 31 failures, true child exit1, no
timeout, unchanged source. CT/xref/Dialyzer/release remain unrun. Its fresh M1a
journey passed including the later rollback assertions and inspection fix.
The failure groups are sixteen physics-view fixtures and one space-view fixture
loading scene/model components without the merged owner/ACL; three GUI examples
trying to install the enlarged user composition through signed edits; seven
generic binder fixtures colliding with the now-composed production space offers;
two physical lifecycle fixtures passing non-ground source clauses as terms;
their dependent restart assertion; and the HTTPS ACL client still selecting the
retired Prolog catalogue name. Corrections remain separately qualified; all
original assertions/deadlines are retained.

- `gate-regressions-01`: 24 tests pass across generic offered operations, live
  GUI examples, HTTPS source ACL and ordinary space views. Those fixtures now
  compose the full GUI owner; the generic binder fixture authors its own offer
  clauses over the same constructor, while stage1 retains production offers.
- `physics-view-regressions-01`: 16 tests, one failure. Fifteen pass with the
  full GUI owner. The remaining test's authored empty view was added alongside
  the newly composed default, retaining a failed source dependency before
  backtracking. It now explicitly replaces that default; its negative dependency
  assertion, source/viewer separation and control checks remain unchanged.
- `physical-lifecycle-regressions-01`: 49 tests, one failure. Source descriptors,
  explicit user hosting and physical startup pass. The earlier fixture had
  withdrawn a lobby's hosting intention and joined a local copy; a later content
  tree restart correctly did not resurrect it. The fixture now explicitly
  restores its hosting intention before testing committed-inventory recovery.
  This is fixture precondition restoration through the existing hosting action,
  not a runtime repair or a weakened recovery assertion. Campaign02 is separate.

`physical-lifecycle-regressions-02` passes all49 cases with the original
assertions and bounds. `live-source-view-02` passes the remaining physics
source/view isolation case; the other15 passed in its retained prior batch.
Clean campaign02 is a new empty stage with unchanged runtime/common/production
source from campaign01, the corrected fixtures, and the current README inventory.
No compiled dependency/application/native artifacts are copied into it.

`public-receipt-02` is an evidence-reader failure (exit127), not a server or
signature failure: the source parser rejected an operation's rendered wire value.
The exact failed reader is preserved. `public-receipt-03` uses the existing
parser3 wire grammar and passes both custody signatures, distinct human/agent
public keys and original human setup-operation identities. It remains offline
and read-only; the running clean campaign is untouched.

Clean campaign02 passes native56 and full EUnit4,251, then fails one of149 CT
cases: `quod_ask_SUITE:remote_gui_opening_observer_receiver`. True CT exit1,
no timeout, authored source unchanged; xref/Dialyzer/release remain unrun.
The migrated CT fixture still loaded gui_instance twice (the former separate
operation/question files), and added a human HUD allowance alongside the new
user template's default. The fixture now composes the full GUI owner once, uses
the shared authored allowance override at genesis, and loads gui_instance once.
No production runtime/common code, deadline or assertion changes. Its real
three-node observer/receiver case is separately checked before campaign03.

`remote-gui-receiver-01` passes the corrected real three-node observer/receiver
case. `static-xref-01` and `static-dialyzer-01` pass on the incremental development
stage, separately labeled preflight checks. They do not replace the required
clean sequential handoff campaign. Production runtime/common/dependency inputs
remain unchanged; the correction is solely the CT fixture composition.

`static-release-01` also passes on the incremental development stage. Clean
campaign03 starts from a new source/dependency-only stage with no compiled
inputs, and runs native → full EUnit → full CT → xref → Dialyzer → local release.
Its current result is pending. The standalone preflights are not substituted
for any clean gate.


Tracker body audit during campaign03: `progress-update-01`,
`review-progress-update-03`, `qualification-progress-update-01` and
`qualification-progress-update-02` all returned outer `isError:false`, but their
nested `bodyWrite` definitively reports `collaborativeBodyStored:false`, with
local snapshot and item fields saved. Earlier success claims based only on the
outer flag were incorrect. The exact directed body retry is retained as
`qualification-progress-update-02-retry-01-result.json` and reports the same
failure. `inputs/tracker-body-write-audit.json` records the complete nested
failure text and responses. No shared-body success, app restart, database/token
workaround or repeated uncertain mutation is claimed. Local tracker reads can
show the updated snapshot while collaborators still have the old body.


Campaign03 passes native56 and full EUnit4,251 (execution1,673.841s,
command1,767.121s), then fails CT148/149: the unchanged signed1200-step
savepoint case returns proof_unavailable. Source was unchanged during that
campaign; later gates were unrun. `inputs/gates-03-failure-index.json` retains
its exact location and result.

`remote-savepoints-diagnosis-01` reuses that unchanged case and adds bounded,
redacted traces. It fails with scope_expired, with no observed codec rejection:
the target made10,507 allocations and8,405 restores, consuming28.16s inside
controller calls before expiry. This is new measured work, distinct from M0's
solved unknown-symbol bad_etf defect. No deadline,1200-step workload or assertion
is changed. The scope owner now retains its controller-authorized, unmaterialized
batch token within the invocation; selection publication, frame completion,
different-batch restoration and reentrant return invalidate it. A pending
allocation marker prevents a late reply from reinstating an invalidated token.
The controller remains the sole authority; no new executor or protocol exists.

`remote-savepoints-diagnosis-02` passes the same case in2.93s, with only5
allocations and2 restores at the target. This is one bounded traced comparison,
not a latency distribution; the before run failed and the after run completed.
The diagnostic suite is retained under inputs and removed from active tests.
`transaction-scope-regressions-01` passes75 tests, including3,075 unchanged
checkpoint/restore pairs with zero controller calls, real foreign rollback and
reentrant invalidation. The full affected ask suite is separately running before
another clean freeze.

The next required clean EUnit invocation enables only the pinned runner's
supported `-v` output option, preserving test semantics, assertions and all
existing timeouts. It will capture per-case timings during that already-required
run, rather than add a separate profiling campaign. The exact runner03 copy and
all previous commands/logs remain retained.


`scope-ask-suite-01` passes all45 affected cases (115.578s command), including
remote signed savepoints, cut/findall, reentry, multi-owner rollback, GUI and
enrollment. Clean campaign04 starts only after that and the75 focused owner tests
pass. Its frozen set contains1,426 authored inputs and1,094 exact dependency
entries; no compiled input is copied. The temporary trace source is archived only
under evidence inputs. No further source changes occur while campaign04 runs.


Final campaign04 passes native56, EUnit4,252, CT149, xref, Dialyzer and local
production release in order. All true exits0, no timeout/unrun gate, and authored
inputs unchanged. The verbose output supplies3,642 named case timings, including
the174.798s integrated M1a journey; unprinted durations are not assigned zero.

`final-consistency-01` failed an evidence-reader assumption: CT recompiles the
same test ebin with different provider flags after EUnit. Founding module hashes
are immutable provenance, not a lifetime implementation lock. The original
reader incorrectly compared them to post-CT objects. No production defect or
core-suite failure is inferred. `founding-beam-rebuild-01` rebuilt source-only in
a separate empty stage with the same EUnit provider and one selected fast identity
test as its compilation trigger. All four objects match the recorded founding
SHA-256 values exactly. Their actual bytes are retained under artifacts; none
was copied into the clean gate stage. `final-consistency-02` passes all11 history
profiles,15 sources,18 archived originals, packaged sources/assets/native output
and unchanged M0 evidence, separately recording EUnit, CT and release objects.

The future campaign runner now retains each provider's Quod objects immediately
after its gate, outside the source/build mount. This avoids another artifact
reconstruction. It does not retroactively claim those copies existed in04:
`inputs/gates-04-gate-campaign.py` remains its exact executed runner. No test,
assertion, deadline or qualified application input changes for this bookkeeping.

Final tracker read01 did not start because automatic approval review timed out;
its exact error is retained. The one explicitly permitted sequential retry02
succeeded. Final item fields stored in-review/44% and the local four-of-nine
checklist, but collaborative body storage again failed. The exact directed
body-only retry also failed; shared publication is not claimed. No app restart,
DB/token workaround, or repeated uncertain mutation occurs.
