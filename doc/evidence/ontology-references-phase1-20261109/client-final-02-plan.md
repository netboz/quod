---
planStatus:
  planId: plan-accounts-by-reference
  title: Space class lives only in quod:space; user ontologies assert instances of it
  status: in-development
  planType: system-design
  priority: high
  owner: Yan
  stakeholders: []
  tags:
    - architecture
    - ontologies
    - spaces
    - gui
    - signup
  created: "2026-11-08"
  startDate: "2026-11-09"
  updated: "2026-11-09T23:38:38.803164+00:00"
  progress: 65
---

# Space class lives only in quod:space; user ontologies assert instances of it

Design only. No production code changes with this document; no deployment,
refound or data wipe is authorized by it. It reads `worktree/pearl-stone` at
0.7.282, the live fleet. `master` is at 0.7.275 and lacks this work.

Words used here: a **user's ontology** is the ontology founded for a human at
signup; it holds the human `me`, the personal agent `personal`, the first space
S0 and, from now on, nothing but facts, ACL clauses and the agent's reactions.
A **class owner** is the ontology defining a class: `quod:space` for `space`,
`quod:gui` for forms, questions and the HUD, `quod:user` for `human_user` and
`personal_agent`, `quod:agent` for `agent`. A **storing ontology** is the one
holding an instance's `instance_of` and slots. **Slot** means the pair
`have_attribute(Class, Key, Type, Default)` on the class and
`attribute(Instance, Key, Value)` on the instance. **ACL** means `can_invoke/4`,
`class_permission/3`, `class_requirement/3` and `instance_permission/3`.

## Implementation checklist

- [ ] **Phase 0 — independent small repairs** (live transaction path)
  - [x] `doc/spaces.md` placement sentence: 2 m in front along −Z plus half the space's depth (Yan, 2026-11-07).
  - [x] Icon byte allowance declared on the icon asset, consumed by the client exactly as model `resources/7` is; delete the client's `1<<20` constant.
  - [x] One icon lookup rule `menu_icon/2` beside `menu_vocabulary/2`; delete `space_icon/2` and the user-ontology `gui_icon/2` forwarder.
  - [x] Yan-authorized gate repairs: isolate resolver trace measurements, remove unreachable refusal arms, and retire the link on an unrepresentable ordered frame.
- [ ] **Phase 1 — the class in one place** (one cold coordinated release for the two engine changes, then live edits)
  - [x] The operation guard runs with ordinary following on (its reads recorded); `no_follow(class_permission/3)` and `no_follow(class_requirement/3)` removed; an instance asserted in the current transaction is checked by its class policy; `'$quod_constructor_graph'` stops refusing a qualified class; constructor bodies and class-built parts are gone.
  - [x] `quod:space`: class declarations and ACL defaults; `inside/3` and `unplaced/1` desired states with their actions; recipes, forms, menus, validators, near-agent pose; `space_instance/2`, `space_contains/2`, the contents projection and `world_view/3` moved in from `common_predicates.pl`; `space_template_hash/1`, `space_recipe/0`, the constructor body and `space_travel/5` deleted.
  - [x] `quod:gui`: question lifecycle, HUD class and rules (kept in `quod:gui`, Yan 2026-11-08), recipes, writing through `::`.
  - [x] `quod:agent`: hosting, custody and recovery actions, writing through `::`.
  - [x] `quod:user`: `personal_agent` class, setup, navigation, controller and personal-menu recipes, personal-instruction rules, the facts, ACL clauses and the one reaction it writes into each new user's ontology; `signup_options/4` writes terms only; `user_source_directory/1`, `user_source_component/2`, `space_source_digest/1` deleted.
  - [x] `gui_forms.pl`: a form owned by another ontology is compiled there; its goal runs where submitted, as today.
  - [x] `quod_client_view.erl`: `navigation`, `controller_preferences`, `hud_commands` goal shapes point at the owner recipes.
  - [ ] Tests (§6) and docs (§2.5, §2.6).
- [ ] **Phase 2 — icon bytes in quod:gui** (live transaction path)
  - [ ] `gui_asset(Digest, Mime, Bytes)` facts in `quod:gui`, public read; 36 icons, 100,690 bytes today.
  - [ ] Client fetches by signed read, verifies the digest, caches by digest; `/assets/icons/` leaves the node image.

Activation clarification from Yan in this session (2026-11-09): backward
compatibility is unnecessary; the ledgers will be refounded. Implementation
therefore proceeds for that eventual activation. Running a refound, deployment
or live edit still requires Yan’s explicit go.

Scope clarification from Yan in this session (2026-11-09): Phase 0 stays
focused on Godot; the existing browser adapters remain unchanged. Their
rejection of the new GUI image shape, including the signed HTTPS lifecycle
test failure, is retained in the
[Phase 0 report](../../doc/evidence/ontology-references-phase0-20261109/report.md).

Scope clarification from Yan in this session (2026-11-09): repair the gate
blockers before Phase 1. Investigate the resolver discrepancy and repair
confirmed defects behind it and the Dialyzer warnings through existing owners;
the browser adapters remain outside this scope.

**Phase 0 validation blocked only by the retained browser rejection:** clean
campaign 03 EUnit exits 1 (4,368 tests, one failure: `expected asset/2`); CT,
xref and Dialyzer exit 0. The resolver measurement defect and all 46 Dialyzer
warnings are repaired. Phase 0's implementation items, including Yan's
authorized gate repairs, are checked; the phase remains unchecked because the
full EUnit gate is not clean. Full exits, causal evidence, production delta
and changed documentation sentences are in the
[gate repair report](../../doc/evidence/ontology-references-phase0-20261109/gate-repairs.md).

**Phase 1 guard-frame scope, authorized after the initial pause:** Yan authorized continuation on 2026-11-09.
Source inspection found that the existing committed guard frame cannot open
foreign scopes, while ordinary foreign invocations use the transaction's
staged view. Preserving committed-only, read-only authorization across those
calls requires a change to the existing scope machinery beyond switching the
guard's local frame. Yan approved refactoring the existing scope owners to carry this restriction
through nested calls, without changing the plan’s rulings or local verdict
checks. Implementation has resumed. The initial evidence and approved scope
are in the
[Phase 1 blocker report](../../doc/evidence/ontology-references-phase1-20261109/guard-frame-blocker.md).

**Phase 1 shared engine item implemented:** Yan’s approved inheritance
correction passes the signed case. The guard follows committed class policy
and runs named checks at the class owner. Original creation context now follows
the transaction revision through re-entry and rollback. Slot preflight follows
qualified class declarations and carries its read-only restriction through
foreign calls; constructor-body execution and part inputs are removed.
The latest focused run passes 100 tests (exit 0), including assertion,
initialization, policy and action-savepoint tests. The retained failure in the
rewritten invalid-order fixture and its correction are recorded in the
[shared engine report](../../doc/evidence/ontology-references-phase1-20261109/shared-engine.md).
The owner moves, normative documentation and full phase gates remain open.

**Phase 1 presentation pause:** the existing class-selected recipe reader still
reads `entity_scene/3` locally before invoking the owner recipe. Moving the
space rule to `quod:space` leaves that reader without class-owned scene
behavior; generic following does not resolve an unqualified instance ID through
its class. Yan approved refactoring the existing presentation reader on 2026-11-09 after
the pause required by his code/plan-mismatch instruction. The reader refactoring
is implemented; the latest focused run passes four tests (exit 0), including
separate storing, class and recipe owners, instance overrides, ACL withdrawal
and unchanged reads without storage I/O. The two failed fixture runs are retained.

**Phase 1 resource-selection stop:** before moving the space rules, inspection
found that local physical resource selection also depends on `space_instance/2`,
`space_assignment/3`, validators and class-selected recipes. Moving these to
the class owner requires foreign reads that resource selection explicitly
forbids. The plan addresses this restriction for the two hosting derivations,
but not these physical dependencies. No owner-move or resource-selector change
has been written. The exact call chains, presentation results, production delta
and documentation sentences are in the
[presentation and resource-selection report](../../doc/evidence/ontology-references-phase1-20261109/presentation-and-resource-stop.md).

Yan approved refactoring the existing physics reader on 2026-11-09 to use
ordinary signed, read-only proofs for class-owner reads. This changes the
documented local-only restriction for those checks. ACLs, original deadlines
and reuse of verified data must remain intact; no copied class rules or new
process are authorized. Implementation has resumed within that scope.


**Phase 1 signed reader remains incomplete:** the approved reader now uses the
ordinary signed path with committed-only restrictions and original deadlines.
The focused runtime case passes class updates, ACL withdrawal and unchanged
repeats without storage I/O. The broader run exits 1: 293 tests, 34 failures.
Whole-ontology read dependencies invalidate physics on unrelated edits; the
existing proof sessions record precise reads, but the signed-read result does
not expose them. Extending that result is awaiting Yan's decision before code.
No additional checklist item is marked complete. The full failure output,
measured production delta and changed documentation sentences are retained in
[the reader report](../../doc/evidence/ontology-references-phase1-20261109/signed-reader-stage.md).

Yan approved extending the existing signed-read result on 2026-11-09 to carry
the precise reads already recorded by the proof. Implementation resumes with
those reads feeding the existing invalidation owner, without another cache or
process. The failed reader report remains evidence of the preceding tree.

**Phase 1 source-permission conflict:** the precise signed-read result is
implemented and its focused validation passes 73 tests (exit 0). Verified
source deltas now preserve selections across unrelated edits. A shared proof
restriction also incorrectly removed transient permission from signed control
calls; that distinction is corrected. The next run passes the first control
command and the unchanged-source checks, but fails after source invocation
permission is withdrawn: the second command returns `reinstalling`.
The existing source-owned physics delegation explicitly survives removal of
source read/disclosure permission. The new signed source reader makes that
permission a requirement for continued physics. Work stops at this conflict
under Yan's instruction; no replacement permission rule has been added and no
assertion has been weakened. Latest result: 36 tests, one failure, exit 1.
Details and exact retained logs are in the
[source-permission stop report](../../doc/evidence/ontology-references-phase1-20261109/source-permission-stop.md).

Yan clarified on 2026-11-09 that ordinary implementation regressions must be
fixed without another permission stop. Work resumes within the approved scope:
preserve the existing installation read and its delegation, and use ordinary
signed scopes for the class-owner calls it needs. The preceding failure and
stop report remain retained evidence.

**Phase 1 implementation resumed:** the retained source reader preserves
installation delegation independently of disclosure ACLs. Precise read sets now
cross the existing scope protocol; the remote signed read/execute/cursor CT
case passes (exit 0, `precise-read-remote-04.log`), after three retained assertion
failures exposed the opaque wire-symbol representation. Resource invalidation
now compares predicate names independently of that representation. The four
remaining focused runtime regressions passed (exit 0), including identity
withdrawal and source ACL continuity. Hosting derivations remain in the storing
ontology; their physical eligibility calls need the same signed class-owner
reader as physics selection.

The space class, actions, projection and forms are being moved to their owner;
this item is not complete. Foreign operation forms now compile, bind and read
defaults at their recipe owner while their returned goal executes where
submitted. The latest broader form run has 37 tests and four creation failures
(exit 1, `owner-form-03.log`), whose decoded refusal is the old
`constructor_body(space)` still used by the fixtures. Those fixtures are being
migrated with the planned constructor removal. No phase gate or additional
checklist item is marked complete.

The signed space-owner creation/action test now passes (exit 0,
`owned-space-action-03.log`): qualified creation and placement commit together;
an unchanged desired state writes nothing; failed destination admission rolls
back; moving and withdrawing update both storing ontologies. Existing space
callers and fixtures still require migration.

Hosting actions have moved to `quod:agent`, using exact agent references and
scoped writes. The local custody check now invokes the storing ontology's
`can_prepare_agent_key/5` ACL directly; its existing assignment checks are part
of that ACL. The focused hosting and custody run passes two tests (exit 0,
`owned-agent-actions-02.log`), after a retained test-helper failure in run 01.
Signing, remaining callers and recovery fixtures are still being migrated, so
the hosting deliverable remains unchecked.

**Signing lookup decision pending:** the signed recovery test passes (exit 0,
`owned-agent-recovery-02.log`), including report replacement and cleanup. The
native signer still proves its permission rule locally in the storing ontology;
the plan moves that rule to the class owner. Yan is asked to approve updating
that existing lookup through the instance's class owner while preserving its
identity, ACL and read-only checks. No native signing-lookup change has been
written. Current partial evidence and measured production delta are in the
[owner-move report](../../doc/evidence/ontology-references-phase1-20261109/owner-move-stage.md).

Yan approved the existing signing lookup change on 2026-11-09. Implementation
resumes using the shared class traversal and named-check dispatch, with the
native call still bound to the exact storing identity. The preceding stop and
its evidence remain recorded; no class-owner decision changes.

**Signing lookup implemented:** the native check now reuses `entity_classes/2`,
`'$quod_class_predicate'/3` and `operation_check/4`, asking each inherited owner
once. Exact storing identity and the original deadline remain unchanged.
`owned-agent-signing-10.log` passes two tests (exit 0): the signed scope test
covers inherited ownership, both ACLs, revoked/staged keys, the wrong host,
read-only enforcement and unchanged repeated reads without storage I/O; the
native fixture covers frame and request-encoding restrictions. Earlier failures
remain retained. The apparent ACL bypass was a fixture deletion that removed
the generic local-entry grant while leaving its node grant; the corrected test
installs the exact intended ACL. Temporary diagnostics have been removed.
The remaining owner moves, callers and full phase gates are still incomplete.


**Personal-instruction rules moved:** admission, signing, retention and lookup
now run at `quod:user`, with exact scoped reads and writes in the user's
ontology. The existing ingress, hosted worker and Godot callers use those
owner calls. `owned-user-regression-01.log` passes 82 tests (exit 0), covering
personal-instruction cancellation, revocation, original-result recovery,
unchanged reads and the full scope-test module. Runs 01–07 remain retained:
01 used an invalid test selector, 02 exposed an operator-pattern mistake,
and 03–07 diagnosed an initial ACL check using a following-enabled frame.
Initial invocation admission now uses the same local-only frame as its
commit-time reproof; operation guards remain separately allowed to follow.
All temporary tracing is removed. Setup, GUI, remaining callers and phase
gates are still incomplete; no additional checklist item is marked complete.


**Setup and controller forms moved:** setup now submits the existing
class-owned operation form with the separately prepared key and receipt as
ordinary inputs. Its definition performs no preparation or live read. The
signed test passes (exit 0, `owned-user-setup-04.log`): invalid receipts and a
refused final acknowledgement leave hosting, membership and placement
unchanged; successful setup commits them together and navigation reads the
current slot. Runs 01–03 retain a missing test brace, an input/output variable
alias rejected by form compilation, and a test binding-selection error.
Godot's startup screen supplies the prepared inputs and keeps its existing
presentation; client core checks pass 358 checks (exit 0,
`owned-user-client-01.log`).
Controller rules and recipes now run at `quod:user`, with exact storing
references. The obsolete controller class check is removed as decided; the
storing owner's ACL and existing owner relationship govern the setter.
Controller validation passes all six tests (exit 0,
`owned-user-controller-02.log`), including private access and live refresh.
Run 01 retains the mistaken editable-form availability expectation, corrected
back to `requires_input`. The user-owner item stays unchecked until signup,
all callers, and the GUI move are complete.

**Question lifecycle moved:** shared transitions and receiver rules now run at
`quod:gui` with exact form, question and human references. Rows, question
membership, ACLs and the completion reaction remain in the storing ontology.
Native handler lookup still starts on the responsible physical host and uses
the original signed request and deadline. Completion status reads the original
operation evidence in the question's storing ontology. Godot and the live-view
validator use the owner-qualified reads and operations.
All six question tests pass (exit 0, `owned-gui-questions-01.log`), including
signed atomic transitions, rollback, concurrent submissions, unchanged reads,
native opening/refusal/cancellation and automatic hosted completion with exact
retained bytes. Focused transition run 05 and opening run 04 also pass. Earlier
labeled failures remain: transition 01 was a missing parenthesis, 02 an
unmigrated receiver ACL entry, 03 a fixed-identity fixture assertion using the
fresh-instance syntax, and 04 an outcome query in the wrong scope; opening 01–02
identified the missing user class owner in the fixture, and 03 an unmigrated
anchored handler-read ACL shape. Temporary tracing is removed. Automatic review
rejected a proposed generic ACL forwarding clause; it was not written. The
implemented entries match the individual receiver/handler calls instead.
The earlier combined user/controller/vault check passed 39 tests (exit 0,
`owned-user-combined-01.log`). HUD, signup, remaining callers and phase gates
remain unfinished; the owner checklist items remain unchecked.

**HUD rules moved:** `quod:gui` now reads the human's exact storing ontology
and owns HUD contributions, offers, withdrawals and the answer form. The
existing `choice(Subject, Eidolon)` carries each contributed command beside
its HUD reference; no new reference type is introduced. The storing ACL
delegates only the enumerated HUD row reads and transitions to the class owner.
Contributor checks run in the owner's ordinary proof, including the current
space owner's authority; no invocation ACL follows another ontology.
Both HUD tests pass (exit 0, `owned-gui-hud-13.log`), including space-owner
revocation, withdrawal of the storing ACL, refused source reads, authored
allowance, offer acceptance/decline and unchanged reads with no traced disk
work. Runs 01–12 remain retained: owner pin setup, inherited Eidolon admission,
GUI form vocabulary/class declarations and the withdrawal fixture were fixed.
The withdrawal fixture's broad retract matched a generic foundation clause
before the human-specific grant; it now installs and verifies the exact
remaining ACL. Temporary diagnostics are removed. The full Godot project
build passed (exit 0, 106 warnings, no errors, `owned-gui-client-build-01.log`)
before the final HUD changes. The combined user, controller, vault, question
and HUD run passes 47 tests (exit 0, `owned-user-gui-combined-01.log`).

**Phase 1 physics validation remains open:** the full focused module run
`owned-physics-suite-01` exited 1: 239 tests, 71 failures. Its complete output
is retained in [the physics log](../../doc/evidence/ontology-references-phase1-20261109/owned-physics-suite-01.log).
Failures include obsolete fixture membership and view ownership, local reaction
validation following the class owner, and component placement. Corrections are
being checked in separately labelled runs; this is not a clean phase gate.
The server signup journey now includes foreign storage, travel and restart,
but that expanded test has not yet been run. Documentation updates and the
[cold release preparation](../../doc/evidence/ontology-references-phase1-20261109/cold-release-preparation.md)
are written; final validation and artifact freezing remain incomplete.

**Phase 1 signed signup and travel journey verified:**
`owned-signup-travel-04` exited 0 after terms-only signup, owner policy checks,
local and foreign creation, placement rollback, same-agent travel, stale offers,
ACL refusal and conflict, recursive contents, and restart/outcome recovery.
Runs 01–03 are retained, including the compilation typo and the rejected travel
form binding. The form now binds only its selected movement goal and exact
final destination, preserving the shared compiler's variable checks.
The full physics rerun `owned-physics-suite-02` exited 1 with 239 tests and
8 failures (71 in run 01). Local reaction matching uses the installed local run
state; signed store and finish actions retain their existing `physics_actor/1`
class eligibility check. Geometry validation reuses its pure integer-coordinate
schema. Focused verification of the eight remaining failures is running.
Production delta at `physics-owner-delta.json`: Phase 1 +2667 / −2327 = +340;
this measurement precedes the travel form binding correction.

**Phase 1 remaining physics fixtures:** `owned-physics-focused-04` exited 1
with eight tests and three failures; `owned-physics-focused-05` exited 1 with
three tests and one failure. Shared component settling now uses the runtime's
installed-structure and sleep notification; recursive projection retains both
the source's explicit scene-read ACL and the class-owner callback ACL. The
remaining hinged-world failure was traced in `owned-hinged-view-01` through
`03` (all exit 1, including a malformed diagnostic term in run 02): fixture
replacement enumerated generated following clauses and reused their bound
variables. The fixture now reads authored source and uses exact retraction.
The full physics rerun is pending; no phase gate is marked clean.

**Phase 1 broader fixture validation:** `owned-physics-suite-03` exited 1
with 239 tests and one concurrency failure (`proof_unavailable` for both
competitors). Its diagnostic rerun passed that case; prerequisite operations
now wait for their existing terminal receipts, and verification remains open.
`owned-recovery-and-race-01` exited 1 on a custody fixture that omitted the
expected host/epoch check; that check is restored. All 24 agent-action tests
pass in `owned-remaining-fixtures-02` (exit 1 overall: 48 tests, five failures).
`owned-remaining-fixtures-03` exits 1 with 24 tests and one remaining world-library
failure; source authoring, signed readback/restart, the lobby and voxel GUI
journeys pass. World-library diagnostics 01–03 and signing runs 04–05 all exit 1
and remain retained. GUI ACLs now match the requested native-handler goal before
checking its application policy, and use the existing local hosting/question
grants before application-policy checks. Completion run 06 exits 1; an obsolete
local `gui_answer` call is corrected to the GUI class owner with the exact
question reference. Temporary production diagnostics are removed. Combined GUI
and physics-race verification is running; full clean gates remain outstanding.

**Phase 1 world-library and concurrency verification:** `owned-gui-and-race-07`
exited 1 with ten tests and one world-entry failure; the physics race passed
with the expected `conflict_retry`. World-entry runs 08–09 and signing runs
10–11 exited 1 and retained the precise `signing_not_authorized` failure. The
GUI callback grant had called `agent_hosted/4` with an unbound instance, combining
multiple actors' hosting rows in its uniqueness check. It now selects the actor
from the existing hosting facts before checking its unique assignment. No grant,
deadline or request identity is broadened. `owned-world-library-12` exits 0:
nine GUI tests, including multiple world creation, physical activation, entry,
unchanged reads and restart. All temporary signing, ACL and physics-race traces
are removed. The full physics and lifecycle modules are next; phase gates and
final evidence are still incomplete.

**Phase 1 broad physics and lifecycle verification:** `owned-physics-lifecycle-04`
exited 1 with 306 tests and two failures. The controller fixture still expected
the removed extra class check to deny the owning human; it now checks that the
other human is denied, preserving the personal-agent save journey. Diagnostic
run `owned-physics-lifecycle-diagnostic-05` exited 1 with 240 tests and two
failures: both competing physics proofs reported `scope_expired`, and the
excluded browser adapter used the obsolete local setup query. The controller
checks passed. Temporary production error logging is removed; the physics
barrier is being diagnosed in the test helper. No clean phase gate is claimed.

**Phase 1 barrier diagnosis and fixture fences:** `owned-physics-barrier-diagnostic-06`
exited 1 with 239 tests and one failure. Its trace showed the first selected
barrier belonged to an already dead proof from an earlier test. The shared test
notification now carries the existing signed operation identity, and concurrent
physics requests match their exact operations. No production timeout or retry
changed. `owned-physics-barrier-07` exited 1 with 386 tests and two different
failures; the original race passed. The native-ACL fixture now replaces its broad
setup grants with the three grants under test, and the motion-query fixture
waits for the existing physics reconciliation after its ACL edits. All temporary
tracing is removed. Focused verification and clean phase gates remain pending.

**Phase 1 fixture fences verified:** `owned-fixture-fences-08` exits 0 with
two tests. Distributed run `owned-agent-failover-01` exits 1: three recovered-work
ACL refusals and two passing uncertain-operation recovery cases. The recovered
actor's fixture ACL used a governed identity query inside the strict local ACL
frame. It now checks its local qualified class membership, matching the existing
user-ontology ACL pattern; signed authentication still verifies the exact anchor
and active key. The distributed suite is being rerun as `owned-agent-failover-02`.
The existing Godot journey has a disposable local fixture prepared through the
shared founding helper; its setup reply-loss probe now matches the offered form.
No fleet action has been run.

**Phase 1 distributed fixtures verified:** `owned-agent-failover-02` exits 0
with all five recovery cases. `owned-remote-gui-01` exited 1 because a shared
fixture used a working-directory-relative source path; the fixture now resolves
both source files through the application `priv` directory. `owned-remote-gui-02`
exits 0 with its remote observer/receiver case. The current inputs are frozen for
clean server campaign 01. Full phase gates, client journeys and final reporting
remain outstanding.

**Phase 1 clean campaign 01 completed:** all 1,504 frozen input hashes are
unchanged. Default/test clean and xref exit 0; EUnit exits 1 (4,349 tests,
51 failures); CT exits 1 (149 passed, one failed); Dialyzer exits 1 (eight
warnings). The EUnit failures and full output are retained in
[the named failure evidence](../../doc/evidence/ontology-references-phase1-20261109/gates-01-eunit-failures.json).
The failures include unmigrated hosting/creation/client fixtures, old resource
trace arities, unsigned resource fixtures and the excluded browser lifecycle.
CT's enrollment readiness check still expected the unqualified agent parent.
The internal committed-read flag is being moved from signed evidence to the
existing proof request record, preserving the signed evidence type. Fixture
corrections are applied after the freeze; focused verification is next. No
phase completion or clean-gate claim is made.

**Phase 1 campaign-01 fixture corrections:** focused run 09 exits 1
(154 tests, 16 failures); its complete failures are retained separately.
Resource selection measurements now observe the current function arity; signed
resource fixtures use the existing node identity fixture. Hosting transitions
use exact references at the class owner; creation-result tests perform their
explicit initialization in the original operation. Run 10 exits 0 (43 tests),
covering the remaining custody, reactions, recovery, replay and space cases.
Replay setup now precedes the test's separate mailbox; recovered fixture agents
carry their class membership. The invalid ACL assertion checks the precise
`not_allowed` refusal and unchanged state. The lens checks its declared qualified
parent; the signed space case verifies inherited `quod:space:thing` behavior.
The client journey fixtures now call setup, questions, instructions and controller
views at their owners. Enrollment CT and exported client verification are next;
full clean gates remain required.

**Phase 1 exported-client verification:** enrollment CT run 03 exits 0.
Client campaign 01 passes JavaScript (295 tests), C# core (358 checks), clean,
Godot export and icons, all exit 0. GUI run 01 exits 1 before startup because
the disposable directory name changes Erlang application resource lookup;
run 02 reaches signup but exits 1 on the old UI wording assertion. Both
fixture issues are corrected with their original logs retained. Export run
02 exits 0; GUI run 03 exits 1 while opening the space view, reporting
`view_not_authorized_or_ready`. The signed lifecycle test now reproduces the
client's complete navigation dependency envelope to diagnose that refusal.
The space refusal fixture now queries the class owner and checks that its
baseline contains actual spaces. No phase completion is claimed.

**Phase 1 navigation dependency refusal reproduced:** focused run 01 exits 0
but used `--test` on a generator and did not execute its checks; it is invalid
verification evidence. Corrected run 02 uses `--generator` and exits 1 with
`not_allowed` at `quod:user`. Its navigation dependency envelope needs the
same public identity read already exposed by the other class owners.
`quod:user` now uses the existing `public_source_query/1` ACL rule; the signed
lifecycle regression keeps the real dependency envelope. Run 03 verifies the
repair before the next exported journey.

**Phase 1 navigation repair verified:** run 03 passes navigation but exits 1
later because the entry-conflict observer still requires the old proof-request
record size. Its cleanup failure is retained in the full log. Both observers
of that record are updated. Run 04 executes the signed lifecycle generator
and ingress module: 21 tests, zero failures, exit 0. Exported GUI verification
continues with the repaired owner ACL and corrected space-state test.

**Phase 1 GUI run 04:** export 03 exits 0. GUI run 04 exits 1 at the
keyboard test after signup, setup recovery and the space projection pass.
The log records `visible=False`: the test edits a hidden form through the
root viewport before the offered action is selected. It now reuses
`ChooseOfferedOperation` and sends input to the field's actual viewport.
This changes the test interaction, not the application's input behavior.

**Phase 1 GUI run 05:** export 04 exits 0. Fresh, reset and live-controller
phases pass. The final phase passes source renewals/revocation, deferred
questions, original-result recovery and negative authorization/binder checks,
then exits 1 because backup export emits a desktop input request in headless
mode (`Unsupported native qualification input`). The existing test click
helper now injects headless window events; the headless host embeds its child
windows, and the backup test closes through the window's existing close signal.
Desktop input still uses its original owned-window driver.

**Phase 1 space journey run 01:** exit 1 because its test still selects the
removed local `space` name. A signed read through the existing signup/setup
fixture (class-selection probe 01, exit 0) returns
`[ontology, quod:space:space]`. The test now selects that qualified class and
checks both the exact `quod:space` class owner and the retained storing ontology.
Exported client verification remains in progress.

**Phase 1 qualified offer duplication:** space journey 02 exits 1 after
`Invalid offered operation binding`; class-selection probe 02 returns each
creation offer twice. The qualified class-existence relation has multiple
proofs, and discovery accidentally multiplies the form rows. The shared
operation/menu subject checks now use `once` for that existence test. A signed
lifecycle assertion requires exactly the three creation operations. Client
name uniqueness validation remains unchanged.

**Phase 1 class/store handoff:** the qualified-offer regression and existing
form/menu suites pass (15 tests, exit 0). Space journey 03 then exits 1 after
selecting Create: the client reopens the class owner as the storing ontology,
which refuses that operation view. The existing pie's signed source is now
passed to the existing operation consumer for class actions. Recipe discovery
uses the exact class owner; execution retains the storing ontology. The
operations panel's selected storage now reads its existing target directly,
removing the duplicate mutable selection. No new reference type or registry is
introduced. Export and live journeys will verify this refactoring.

**Phase 1 canonical class selection:** export 07 exits 1 on a C# local-name
collision; export 08 exits 0 after correction. Space journey 04 passes actual
creation, lost-reply recovery, exact class/storage checks and another device's
result lookup, then exits 1 on cancelled-draft recovery. Selection constructed
a storing-qualified reference while the menu returned the exact class-owner
reference, producing different draft identities. Existing class discovery now
returns exact `class_ref` values, and the selector consumes those references
without constructing another identity. The existing menu read accepts that
same anchored class reference through the shared subject resolver; a wrong
class anchor is covered in the signed lifecycle test. A cleared form rejects
its retiring control's input callback. The stale-form test now changes the
stored destination's name slot, which actually changes the owner-compiled
form's options, instead of adding an obsolete local form-context clause.
The GUI implementation document states the exact class-reference result and
retained storing ontology; its final sentence diff will include this update.

**Phase 1 exact-reference validation:** focused run 01 exits 1 (20 tests,
one failure): the wrong-anchor assertion expected plain `fail` instead of the
actual structured read `failed` result. The corrected lifecycle run 02 exits
0 and retains the refusal check. The other 19 form/menu checks passed run 01.
[Documentation review 02](../../doc/evidence/ontology-references-phase1-20261109/documentation-review-02.md)
records every changed normative-document sentence, including the exact class
reference discovery contract. Final clean gates remain outstanding.

**Phase 1 space journey 05:** export 09 exits 0. Creation and recovery still
pass; the final phase exits 1 at the combined cancel/reopen draft-and-write
assertion. The test now checks the active draft, reopened draft and write count
separately, retaining both obligations and reporting their actual values.
The cause of that remaining failure is not yet established.

**Phase 1 space journey 06:** exit 1 at a stale placement-role lookup after
cancel/reopen retains `Preserved draft` and writes remain exactly 5 before and
after. The stale-revision and adoption checks also pass. Placement roles now
include the selected ontology reference. The typing helper waits for the actual
`TextChanged` signal instead of one frame, so cancellation follows processed
input. Draft identity includes the storing ontology as well as the exact class;
the exported journey checks separate drafts for two storing ontologies. The
foreign fixture explicitly grants the existing class-list and class-menu reads
needed for that same creation journey, alongside its existing creation grant.

**Phase 1 space journeys 07–09:** runs 07 and 08 exit 1 when the existing
progress watchdog stops the client during destination-admission refusal. Run 08
measures the server response at 0.6225 seconds and forwarding at 0.0040 seconds;
the response is 1,040,683 bytes. No request deadline or resubmission policy has
changed. Run 09 exits 1 earlier with a native Submit-click timeout. The test now
reuses its existing `NativePress` helper, including layout and pointer-miss
evidence, instead of maintaining a second click implementation. Temporary
response-handling markers will locate the original client stall and be removed
before clean gates. All three failed logs and private fixtures are retained.

**Phase 1 refusal display diagnosis:** space journey 10 exits 1 with the
watchdog error. Its temporary markers show that response handling reaches
`ShowOutcome` and then stops inside creation of the wrapped exact-details
label. The complete reply now uses the existing read-only, scrollable text
control with wrapping disabled; no response cap or dropped reason is added.
The exported refusal check compares the displayed JSON with the actual outcome.
Temporary production markers are removed before rebuilding.

**Phase 1 exported spaces verified:** run 11 exits 1 on a native-pointer miss
before dispatch; the test helper now waits for the existing installed-layout
notification. Run 12 exits 0, including complete scrollable refusal details,
destination denial rollback, wrong-anchor refusal, separate storing-ontology
drafts, lost-reply recovery, another device's result lookup, and owner restart
with no duplicate creation. All temporary production trace markers are removed.
GUI/controller and navigation journeys and the final clean server gates remain.

**Phase 1 GUI/controller run 06:** exit 1 at the controller-resource check:
no source had been registered and all resource counters were zero. The tracker
registration callback is deferred; the test now waits for the existing controller
owner's change notification before awaiting model loading. Navigation's three
remaining direct `space_represent` fixture calls now use the class owner and
exact subject, matching the existing production signature. No production
controller path or timing budget changed.

**Phase 1 GUI run 07 and local backup probe 01:** both exit 1 at the backup
window's native Apply click. Controller/model renewal, source editing/revocation,
questions, original outcomes and negative ACL/binder checks pass before it.
The retained pointer diagnostic measures an embedded 1×1 window and viewport
under the headless display. The headless pointer adapter now sizes that window
to its qualification host and waits for the native container's installed layout
before clicking. Production backup behavior is unchanged. Local crypto and the
full GUI journey will verify the adapter correction.

**Phase 1 local backup probe 02:** exit 1. The retained diagnostic confirms
window and viewport are now 1200×800, but direct embedded-window input reaches
no hovered control. The headless pointer adapter now sends window-relative
input through the embedding owner. The local driver also disables XR startup,
matching the other non-headset journeys; probe 02 retained its incidental XR
startup errors. No production input path changes.

**Phase 1 local backup probe 03:** exit 1; parent routing alone does not fix
the native hover. The pinned engine API explicitly requires `NotifyMouseEntered`
before injected pointer events. The adapter now sends that notification to the
target viewport, retaining local coordinates; the ineffective parent-routing
change is removed. The failed probe is retained.

**Phase 1 local backup probes 04–05:** both exit 1. Probe 05 records the
actual sent pointer at y=1985.5, then the installed Apply control at y=139.5.
The click runs reentrantly from the first native layout callback while wrapping
is still updating the container. Layout-fence task continuations now resume
asynchronously after that callback returns. This is test synchronization; no
production backup change or assertion weakening is introduced.

**Phase 1 local backup verified:** probe 06 exits 1 with stable coordinates
but no embedded-window hover. The existing native embedding owner must route
pointer input; combined with asynchronous layout completion, probe 07 exits 0.
Wrong-passphrase rejection, authentication-tag tamper rejection, exact identity
import, signature/codec checks and encrypted export all pass through the actual
backup widget. The native test helper retains coordinate evidence on failures.
No production backup change was needed. Full GUI and navigation remain pending.

**Phase 1 GUI run 08:** every behavioral check passes, including backup,
but the driver exits 1 on shutdown resource-leak errors (one viewport, scenario
and camera, textures and text resources). The source-view fixture created a
preview without mounting it as the production host does; its normal native
child ownership never initialized. The fixture now mounts that existing
preview. The next run enables verbose shutdown evidence to verify remaining
resources instead of suppressing errors or weakening the exit check.

**Phase 1 GUI run 09:** exit 1 solely on remaining shutdown leaks; all
behavioral checks pass. Verbose diagnostics confirm the preview viewport,
scenario and camera leaks are gone and identify one unparented Button. The
reopened-question fixture did not host or release its separate choice button.
It now mirrors the existing question hub's ownership and cleanup. No production
resource lifecycle has been changed for these fixture leaks.

**Phase 1 exported GUI verified:** run 10 exits 0, including controller
resources, backup, source views, reopened questions and clean shutdown. The
temporary verbose engine diagnostics are removed. Navigation and the final
clean sequential gates remain pending.

**Phase 1 exported navigation verified:** run 01 exits 0. Nested creation,
recursive exact-subject display, travel and lost-reply recovery, denied entry
and the original uncertain-operation barrier pass. Three unchanged signed
renewals perform no reader/history/native-install or file write/sync work.
The candidate is frozen for clean sequential server campaign 02 and the final
client campaign; phase completion remains unclaimed.

**Phase 1 clean campaign 02 completed:** all 1,511 input hashes are unchanged.
CT passes all 150 tests; xref and Dialyzer pass, each exit 0. EUnit exits 1
with 4,349 tests and two failures: the excluded browser acceptance driver
uses the former local setup query; the source-access test still expects public
Eidolon discovery to refuse. The latter now checks discovery and refusal of
the actual source view, retaining the predicate-source refusal and mutation
checks. No production change accompanies this fixture correction. Full failure
output is retained in `gates-02-eunit-failures.txt`. Focused verification and
the final clean gates follow; no phase completion is claimed.

**Phase 1 source-access fixture verified:** `owned-public-source-discovery-01`
exits 0. Public discovery, private source-view and predicate-list refusal, and
the existing unauthorized-mutation checks all pass through signed calls.
Campaign 03 freezes this test-only correction for the final clean server gates.
The production delta and nine-document review are unchanged.

**Phase 1 final server and client campaign 01:** server campaign 03 exits
EUnit 1 (4,349 tests, solely the excluded browser setup query), CT 0 (150
passed), xref 0 and Dialyzer 0. All 1,512 frozen inputs remain unchanged.
Client campaign 01 passes every gate, including all exported journeys and
backup, with the same unchanged inputs. Export inspection nevertheless finds
old local test profiles included from the existing output directory. Content
probe 01 is stopped with child exit −15 because release templates do not run
its script; the pinned editor probe 02 confirms the unwanted directory and
exits 1. The existing export preset now excludes its output directory. Client
campaign 02 rebuilds and checks this packaging-only correction. No server
source or test changes accompany it, and all failed evidence is retained.

## 1. Rulings

Yan, 2026-11-08:

1. A class is defined in one owner; other ontologies call it through `::`.
   ACLs are the only protection. `space` is defined in `quod:space` only. The
   signup paste of `quod_space.pl`, `user_instance.pl`, `agent_instance.pl`,
   `gui_instance.pl` is removed.
2. `space_template_hash/1`, `space_source_digest/1`, `user_source_component/2`
   are deleted with no replacement.
3. Icons, names and bytes, are predicates in `quod:gui`; changes propagate
   only through commit, then the dependent live views refresh.
4. Creating a thing is asserting it: `assert(instance_of(…))` in the storing
   ontology, under the user's identity and that ontology's ACL.
5. Slot values are stored with the instance, for every class.
6. A rule in one ontology writes into another through `::`; the target's ACL
   admits it or not. Nothing else decides (`test/quod_ask_tests.erl`:
   `pets::assertz(origin_callback_write)`; multiwrite "one foreign writer").
7. ACL edits are assert and retract of ACL facts; `set_instance_permission/3`
   is a helper. The ACL of a space is stored with the space. A space does not
   change its storing ontology; only references to it move.
8. Reactions (`react_on/2`) are stored clauses, Prolog like everything else,
   and are an agent's behaviour: the spec says the selected goal "enters the
   matching hosted actor's bounded queue and then the ordinary signed-goal
   path". Above reactions sits the `goal/1` and `action/3` pattern: putting an
   instance into a space is `quod:space::goal(inside(Space, Instance, Pose))`,
   with the action's prerequisites filling in what the caller left out.
10. Instances are asserted, by the user or by a form's goal; constructors do
    not build instances. An asserted instance is placed in the same
    transaction.
9. No follow-ups. Icon bytes by signed read. Existing users sign up again.

## 2. How it works

### 2.1 Creating a space, and placing it, in one transaction

The user, in the storing ontology, runs the Create form's goal:

```prolog
with_build_plan([attribute(name, Name), attribute(dimensions, D), attribute(exterior, E)],
                assert(instance_of(quod:space:space, B))),
quod:space::goal(inside(A, entity_ref(Ns, Anchor, B), Pose))
```

The storing ontology's own assertion step does what it does today, with one
difference: the class is at `quod:space`.

1. **Permission.** "May this actor create a `quod:space:space` here?" The
   shared guard walks the class tree with `isa/2`, collects
   `class_requirement/3` and `class_permission/3` from every class on the way,
   most specific wins, `instance_permission/3` overrides. `isa/2` already
   follows a qualified class into its owner ("Once a path reaches a foreign
   class, ask its owning ontology for the rest of the public isa/2 relation",
   `common_predicates.pl`). Two things stop the guard from using that
   inheritance, both put there for the paste model. **Change:** remove
   `no_follow(class_requirement/3)` and `no_follow(class_permission/3)`
   (`common_predicates.pl:331-332`, "Policy data is local to the target"), so a
   qualified class's defaults are found at its owner like its parents are; a
   plain local class name follows nothing, so a local denial never becomes a
   foreign grant. And run the operation guard
   (`quod_ask:committed_authorization_result/2`) in an ordinary read-only
   committed frame with following on and its reads recorded, instead of the
   committee-verdict frame where following is switched off
   (`quod_erlog_db_local_prove.erl:73`). `can_invoke/4`, custody and committee
   verdicts keep their frame; validators re-prove those without network.
   Writes stay forbidden in the guard.
2. **Id.** Allocated locally, as today.
3. **Slots.** Declarations read at `quod:space`
   (`'$quod_constructor_graph'` drops its `constructor_requires_local_class`
   refusal), defaults resolved, type checks run at the owner, values stored as
   `attribute(B, Key, Value)` in the storing ontology, as today for every class.
   `transform` is a slot with default origin.
4. **No constructor body.** Instances are asserted; constructors do not build
   instances or parts. The exterior-versus-dimensions check becomes
   `class_requirement(space, create, space_exterior_fits)` at the owner.
5. **Placement in the same transaction.** `goal(inside(A, B, Pose))` runs the
   `place` action (§2.2). A is committed: its admit ACL is checked as usual.
   B's `instance_of` is only staged: the guard checks B by its class policy,
   read through inheritance, as it already does inside a constructor
   ("checked as `construction(Class, Id, Inputs)` … uses class grants without
   staged instance overrides"). **Change:** that treatment applies to any
   instance whose membership was asserted in the current transaction, not only
   inside a constructor body. The actor who asserted it has already passed the
   class-level create check, so the class policy is the right authority for its
   first placement.
6. **ACL of the new space.** The same transaction may assert
   `instance_permission(B, space_admit, …)` and so on in the storing ontology.
   They apply from the next transaction.

One commit: B exists, placed in A.

### 2.2 Placing anything anywhere: `goal(inside(...))`

`quod:space` declares two desired states and their actions, using the existing
`goal/1`, `action/3`, `satisfy_prerequisites/2` machinery of
`common_predicates.pl`. Prerequisites are ordinary goals; they bind what the
caller left unbound (today's `action(initialize_agent_host(…), [current_principal(Administrator), …])`
binds `Administrator` the same way).

```prolog
%% inside(Space, Entity, Pose): Entity is placed in Space at Pose.
inside(entity_ref(SNs, SA, Space), entity_ref(ENs, EA, Entity), Pose) :-
    in_ontology(ENs, EA, (space_assignment(Entity, _, entity_ref(SNs, SA, Space)),
                          attribute(Entity, transform, Pose))).
unplaced(entity_ref(ENs, EA, Entity)) :- in_ontology(ENs, EA, space_assignment(Entity, _, none)).

action(place(Space, Entity, Pose),
       [goal(unplaced(Entity)),                              % leaves the current space first
        placement_pose(Space, Entity, Pose),                 % binds Pose when the caller left it open
        space_authorized(Entity, space_enter, Space, placement),
        space_authorized(Space, space_admit, Entity, placement)],
       inside(Space, Entity, Pose)).
action(withdraw(Entity),
       [current_assignment(Entity, Revision, Space),
        space_authorized(Entity, space_leave, Space, placement)],
       unplaced(Entity)).
```

`place/3` and `withdraw/1` write, through `::`, `space_assignment_state/3` and
`attribute(Entity, transform, Pose)` in the entity's storing ontology, and
`space_placement/3` in the space's storing ontology, plus the physical hook
when the destination is physical. Each write is admitted by that ontology's
`can_invoke/4` for the acting principal with `quod:space` in the call chain.
The ACL checks are the existing shared guard over the storing ontologies'
committed facts: `space_authorized/4` asks the entity's ontology and the
space's ontology through `::`. The revision counter stays inside
`space_assignment_state/3` as today. One `goal(inside(...))` is one atomic
transaction over every ontology it writes.

Every placement is this one goal:

- Create B near the agent: the form's goal asserts B and runs
  `quod:space::goal(inside(Current, B, _))`; `placement_pose/3` binds the pose
  2 m in front of the agent plus half B's depth.
- Create an avatar made of parts: the same form goal asserts the avatar space
  and each part with their slots, then one `goal(inside(Avatar, Part, Pose))`
  per part, whichever ontology stores them. Parts are asserted like anything
  else; no class builds them.
- Enter S1: the Enter form's goal is `quod:space::goal(inside(S1, personal, Pose))`;
  the `goal(unplaced(personal))` prerequisite runs `withdraw` first. This
  replaces `space_travel/5`.
- Leave: `quod:space::goal(unplaced(personal))`.
- Setup: one transaction hosts the agent, asserts S0 and runs
  `goal(inside(S0, personal, transform(0,0,0,0,0,0)))`; S0's admit ACL is its
  class policy, since S0 is asserted in that transaction.
- Display membership (`space_contain/2`, `space_remove/2`) becomes
  `goal(shown_in(Space, Entity))` and `goal(not_shown_in(…))` on the same
  pattern.

### 2.3 Reactions as the agent's behaviour

The personal agent's ontology holds one reaction, written at signup:

```prolog
react_on(assert(gui_question(Q, Source, Human, Actor, Revision, Submitted)), quod:gui::gui_complete(Q)) :-
    gui_completion_event(Q, Source, Human, Actor, Revision, Submitted).
```

It is today's question completion reaction with its goal at the class owner. A
reaction's goal runs through the hosted actor's queue as a signed operation
under ordinary ACLs. Reactions on events of another ontology use the existing
`from(Ns, Anchor, Pattern)` form with `subscribes/2`. Placement needs no
reaction: it happens in the creating transaction (§2.1).

### 2.4 Forms, menus, HUD, questions, hosting

Forms, menus and Eidolon recipes stay class-owned and are already evaluated at
their owner through `in_ontology/3`. A form owned by another ontology is
compiled there (the `form_ref` pattern questions already use); its goal runs
where submitted. Renaming, Show as and controller settings are forms whose goal
retracts and asserts the slot in the storing ontology; the diff reaches the
client through the existing live views.

The HUD is `instance_of(quod:gui:hud, my_hud)` asserted in the agent's ontology
with its slots and allowance. `quod:gui` holds the HUD rules
(`hud_contribute/2`, `hud_offer/2`, `gui_link_question/1`, …) and writes
`hud_contribution/4`, `hud_offered/4`, `gui_pending/2` into the agent's ontology
through `::`, admitted by its ACL. The HUD commands recipe at `quod:gui` reads
them back the same way. Questions: `quod:gui` holds the lifecycle
(`gui_open/2`, `gui_submit/4`, `gui_complete/1`, `gui_consume/1`, …) and writes
`gui_question/6` rows into the responding agent's ontology through `::`.
Hosting: `quod:agent` holds the actions (`initialize_agent_host`,
`assign_agent_host`, recovery, custody) and writes `agent_key/3`,
`agent_host/4` and recovery rows through `::`.

One exception the spec itself imposes: the node selects the agents an ontology
hosts in the "local installed-resource selection" context where "live queries,
scope calls, staging and reaction commands are forbidden". So the two
derivation clauses `agent_hosted/4` and `agent_hosting_projection/4` stay as
clauses in each hosting ontology, written at signup beside the hosting facts.
Everything else in `agent_instance.pl` moves to `quod:agent`.

### 2.5 `doc/proofs.md` sentences that change

Current text, then replacement; each needs Yan's decided-by annotation.

- "Checks must be pure committed Prolog: they cannot write, consult live
  services or open foreign scopes." → "Checks must be pure committed Prolog:
  they cannot write or consult live services. The class tree and class ACL
  declarations follow a qualified class into its owner, as `isa/2` does; those
  reads enter the plan's dependencies. `can_invoke/4`, custody and committee
  verdicts cannot follow."
- "Derived memberships and the entire ancestry consulted by the guard follow
  the same rule: a foreign-qualified parent is refused, not partially
  evaluated." → "…a foreign-qualified class is followed to its owner."
- "Compose class policy into its target ontology, as for other local
  authorization." → "The class owner declares the class's ACL defaults and
  compulsory requirements; the storing ontology declares per-instance ACL
  facts."
- "Class definitions and constructors are composed locally, like shared
  permission policy; a foreign-qualified parent is refused rather than silently
  skipped." → "Class declarations follow a qualified class to its owner.
  Constructors do not build instances or parts; a `constructor/3` clause at a
  foreign owner refuses."
- "The assertion hook alone supplies this scoped context; callers cannot
  supply that subject to the public guard or forge it with build inputs." →
  "An instance whose membership was asserted in the current transaction is
  checked by its class policy, without staged instance overrides, until it
  commits."
- "Classes author their own bodies and required parts." and "class code still
  constructs its required parts and explicitly passes overrides" → deleted;
  parts are asserted like any instance.
- Runtime: add to `doc/runtime-and-agents.md` "A reaction is an agent's
  behaviour: an ontology without a hosted agent can hold `react_on/2` clauses
  but nothing executes them."

### 2.6 Other sentences that change

`doc/spaces.md`: "`quod_space.pl` defines the shared space foundation and is
composed into the ontologies owning individual spaces … the shared
foundation's exact pin and source hash certify the composition" → "`quod:space`
defines the space class. A storing ontology holds
`instance_of(quod:space:space, Id)`, its slots and its ACL facts."; "Compose
`quod_space.pl` into that storage owner and A's ontology…" and "Compose
`quod_space.pl` and `gui_instance.pl` in the storage owner to offer **Create
space**…" → delete; "Creation and form definition check the unique anchored
`space_vocabulary/2` plus `space_source_digest/1` against the shared source's
`space_template_hash/1`…" → delete; "places it one metre along that frame's X
axis from A." → Phase 0; "Creation and placement use the existing assertion
savepoint and `space_place/3` transaction. Refused explicit placement rolls
back the instance and all admission writes" → "Creation asserts the space and runs `goal(inside(…))` in the same
transaction; a refused placement fails the transaction as today."; the
`space_place/3`, `space_withdraw/3`, `space_travel/5` and `initial_occupants`
paragraphs → the `inside/3` and `unplaced/1` actions; "Participant entries
cannot create or release a slot" stays true of `place/3` and `withdraw/1`.

`doc/runtime-and-agents.md`: the `setup_account/4` paragraph → the setup form
of §4.3. `doc/godot-foundation-contract.md` step 5 ("the frozen private
account source composition, `user_source_directory`…") → terms only; the
"places A in S0 through `space_place/3` during that active construction"
sentence → `goal(inside(S0, personal, origin))` after the assertion, same
transaction.
`doc/lifecycle-and-routing.md`: keep `source_file(Path, Sha256)` for the node
template; drop "This lets an authored recipe pin packaged components".

## 3. Phase 0 — independent small repairs

### 3.1 `spaces.md` placement sentence

Code and test already agree (`quod_space.pl:112-125`; lifecycle test expects
`{transform,0,0,-52000,0,0,0}` for the default 100 m box). Replace "places it
one metre along that frame's X axis from A." with "places it in front of A
along that frame's −Z axis: 2 m from A's position plus half the new space's
depth, so its near wall opens at arm's reach plus a step (Yan, 2026-11-07); an
infinite space uses half-depth zero."

### 3.2 Icon byte allowance from the authored asset

Models declare it: `gui_scene.pl:136` has `mesh_asset(asset(Digest, Mime),
Profile, scale, frame, resources(Transfer, Geometry, Vertices, Triangles,
Nodes, Materials, Pixels))`, authored per asset (`quod_controllers.pl:41`),
admitted by the client (`StaticGlb.Admit`, `Transport.Model(digest,
allowance)`). Icons declare nothing. Change the `image` property value from
`asset(Digest, Mime)` to `image(asset(Digest, Mime), resources(Transfer,
Pixels))` in `quod:gui`; `image_asset/1` and `optional_image_asset/1` accept
it; the 36 `gui_icon/2` facts carry byte length and pixel count measured from
the files. `Forms.cs`, `Menus.cs` and `Main.FetchIcon` pass the declared
allowance to `Transport.Icon`; the constant goes.

### 3.3 One icon lookup

In `common_predicates.pl` beside `menu_vocabulary/2`:

```prolog
no_follow(menu_icon/2).
menu_icon(Name, Icon) :- menu_vocabulary(Gui, Anchor), in_ontology(Gui, Anchor, gui_icon(Name, Icon)).
```

Delete `space_icon/2` and the user-ontology `gui_icon/2`; eleven callers use
`menu_icon/2`. Not named `gui_icon/2` because inside `quod:gui` that is the
fact table.

## 4. Phase 1

### 4.1 What each ontology holds afterwards

| Ontology | Holds |
| --- | --- |
| `quod:space` | `isa(space, thing)`, `isa(physical_space, space)`, `space_instance/2`, `space_contains/2`, the contents projection and `world_view/3` (moved out of `common_predicates.pl`), slots, `class_permission(space, create\|space_enter\|space_admit\|space_leave\|space_remove\|space_visit\|space_represent, allow)`, `class_requirement(space, create, space_exterior_fits)`, `inside/3`, `unplaced/1`, `shown_in/2` and their actions, `placement_pose/3`, `space_half_depth/2`, every recipe (solid, wireframe, matrix, contents, menu, hud), Create / Enter / Leave / Show as forms, `can_invoke` for its public reads and goals |
| `quod:gui` | vocabulary as today; question lifecycle; HUD rules and recipes; `ontology_interface/2`; Phase 2 bytes |
| `quod:agent` | `isa(agent, thing)`, `class_permission(agent, space_enter\|space_leave, allow)`, hosting, custody and recovery actions |
| `quod:user` | `isa(human_user, agent)`, `isa(personal_agent, quod:agent:agent)`, setup, navigation, personal menu, attention, controller recipes and forms, personal-instruction rules (`personal_instruction_accept/2`, `retain_personal_instruction/3`, lookups), `signup_options/4`, the terms it writes into a new user's ontology |
| user's ontology | facts: `user_namespace/1`, `instance_of(quod:user:human_user, me)`, `instance_of(quod:user:personal_agent, personal)`, `agent_key/3`, `agent_host/4`, `hosting_node/1`, `signup_origin/3`, the seven vocabulary pins, `account_setup/2`, `instance_of(quod:gui:hud, my_hud)`, `hud_allowance(my_hud, 12)`, `gui_pending_allowance(me, 8)`, `entity_scene(personal, playing\|edition, hidden)`; ACL clauses: `can_invoke/4` for U (all), for `personal` (the exact goals it may run here), for writes arriving through `::` from `quod:space`, `quod:gui`, `quod:agent`, `quod:user` under U's or A's identity, and for the node's signing reads; `instance_permission/3` facts on its spaces; reaction: the clause of §2.3; the two hosting derivation clauses of §2.4 |

### 4.2 Where every pasted rule goes

**owner** = lives in the class owner and is called by `::`; **fact** / **ACL**
/ **reaction** = written into the user's ontology at signup; **deleted**.

`quod_space.pl` (572 lines): `can_invoke`, `space_query` → owner only, the
`space_template_hash` query deleted. `isa/2`, slots, `have_part` → owner.
`space_recipe/0`, constructor body, `space_initial_occupants/2`,
`space_initial_local/3`, `space_place_initial/2`, `space_travel/5`,
`space_icon/2` → deleted. `space_place/3`, `space_accept_placement/3`,
`space_withdraw/3`, `space_release_placement/4`, `space_expected_assignment/3`,
`space_contain/2`, `space_remove/2`, `space_consent/4`,
`space_withdrawal_consent/4`, `space_removal_allowed/3` → owner, rewritten as
the `place/3`, `withdraw/1`, `show/2`, `hide/2` actions behind `inside/3`,
`unplaced/1`, `shown_in/2`. `space_assignment/3`, `space_location/2`,
`space_subject/2`, `space_authorized/4`, `space_change_physics/3`,
`space_physical_change/3` default, `space_represent/7` and helpers,
`space_representation_changed/2`, `space_near_location/3`,
`space_half_depth/2`, `space_millimetres/4`, `space_whole_mm/2`, all
validators, recipes, forms and menus → owner.

`user_instance.pl` (699 lines): `can_invoke(_, agent_instance_ref(Ns, _, I), _, Ns) :- instance_of(quod:user:human_user, I)`,
`can_invoke` for A's goals, callbacks and the instruction authority, the node
signing clauses, `can_prepare_agent_key/5`, `can_assign_agent_host/6`,
`hud_entry/2`, `hud_offer_entry/2` as `can_invoke` over the owner's relations
→ **ACL**. `human_user_owner/1`, `account_owner_policy/1`,
`ontology_source_mode/1` → **ACL** helpers (two lines). The seven
`class_permission` checks (`account_space_create/3`, `account_space_admit/3`,
`account_new_space_entry/3`, `account_agent_entry/3`, `account_agent_leave/3`,
`account_space_visit/3`, `account_space_represent/3`, `account_initial_entry/3`,
`account_personal_actor/2`, `space_travel_agent/1`, `controller_actor/3`,
`hud_answer_actor/3`) → replaced by `instance_permission/3` facts set at
creation and the owners' class defaults; what remains is "which goals may my
agent run here", an `can_invoke` matter → **ACL**. `gui_pending_allowance/2`,
`hud_allowance/2`, `instance_of(quod:gui:hud, my_hud)`,
`instance_of(quod:user:personal_agent, personal)`, `entity_scene(personal, …, hidden)`
→ **fact**. `account_setup_state/1`, `account_navigation/1,2`,
`account_setup_preparation/1`, `setup_account/4` (as the `setup` form),
`personal_menu` and helpers, `personal_agent_owner/1`, `personal_agent/2`,
`personal_agent_preparation/1`, `personal_instruction_accept/2`,
`can_instruct_personal_agent/2`, `personal_instruction_authorized/5`,
`can_sign_agent_request/3`, `can_request_agent_signature/3`,
`retain_personal_instruction/3`, `personal_instruction_retained/2`,
`personal_instruction_lookup/3`, `personal_instructions/1`, controller
preferences reads, forms and `controller_preferences_set/5` → owner
`quod:user`. `gui_unlink/2`, `gui_hud_entry/4`, `gui_pending_questions/1`,
`gui_select_receiver/3`, `gui_forget_receivers/1`, `gui_receiver_for/2`,
`gui_receiver_accept/3`, `gui_link_question/1`, `hud_commands/1`,
`hud_command/1`, the attention recipe, `hud_direct_contributor/1`,
`hud_contribute/2`, `hud_withdraw/2`, `hud_offer/2`, `hud_withdraw_offer/2`,
`hud_answer_offer/3`, the `answer_hud_offer` recipe and `hud_offers(H)` form,
`hud_offer_label/3` → owner `quod:gui`. `account_source_pins/1`,
`account_space_recipe/1` → deleted.

`agent_instance.pl` (284 lines): `agent_hosted/4`,
`agent_hosting_projection/4` → clauses in the hosting ontology (§2.4
exception); everything else → owner `quod:agent`. The node ontology's
`node_identity_template` and the lobby lose their copies the same way.

`gui_instance.pl` (379 lines): the question lifecycle, entry relations,
`gui_responder_for/4`, `gui_native_handler/5`, `gui_accept_question/1`,
`gui_accepting/1`, `gui_open/2`, `gui_open_definition/5`,
`gui_validate_submission/6`, `gui_form_projection/4`, `gui_continue/1`,
`ontology_interface/2` → owner `quod:gui`; the completion `react_on/2` →
**reaction**; `gui_completion_allowance/2`, `gui_pending_allowance/2` →
**fact** where authored; `gui_question_policy/3` stays an application fact
where an application composes it.

### 4.3 What signup writes

`signup_options/4` in `quod:user` returns
`[terms(Facts ++ Pins ++ Acl ++ Reactions), external_predicate_modules([quod_agent_predicates])]`,
nothing else. The ACL clauses and reactions are authored once in `quod:user` as
`account_policy_clause(Clause)` facts; about forty clauses. They are the user's
own ACL, editable by the user with owner authority.
`ontology_creation_allowed/3` validates that exact term list.
`user_source_directory/1`, `user_source_component/2`, `space_source_digest/1`
and the `space_template_hash/1` read are deleted.

Setup is the `human_user` class's `setup` form at `quod:user`; its goal runs in
the user's ontology:
`quod:agent::goal(agent_hosted(personal, Node, 1, Key))`, then the S0 assertion
with `attribute(owner, Owner)`, then
`quod:space::goal(inside(entity_ref(Ns, A, S0), entity_ref(Ns, A, personal), transform(0,0,0,0,0,0)))`,
then the `account_setup/2` fact flip and
`in_ontology(Signup, SignupAnchor, acknowledge_signup(Token, Owner))`. One
transaction, as today. The preparation read and `prepared_agent_key_custody/6` are
unchanged. The stored `complete(Result)` term is kept: it is the immutable
setup record the client recovers.

### 4.4 Engine and shared-file changes (one cold release)

- `quod_ask:committed_authorization_result/2`: the operation guard runs in an
  ordinary read-only committed frame with following on and reads recorded
  (§2.1 step 1); an instance asserted in the current transaction is checked by
  its class policy (§2.1 step 5). `can_invoke/4`, custody and verdict keep the
  committee-verdict frame.
- `construction.pl`: `'$quod_constructor_graph'` follows a qualified class to
  its owner for parents, `constructor_order/2` and slot declarations; a
  `constructor/3` clause at a foreign owner refuses; `have_part/2`,
  `build_plan_part/3` and part inputs are removed.
- `common_predicates.pl`: `no_follow(class_requirement/3)` and
  `no_follow(class_permission/3)` removed; `menu_icon/2`;
  `isa(ontology, quod:space:space)` replaces `isa(ontology, space)`;
  `isa(space, thing)`, `space_instance/2`, `space_contains/2`,
  `space_projection/3,4`, `space_contents_projection/2`,
  `space_exposure_projection/4`, `space_scene_parts/8` and the rest of the
  contents projection (lines 649-812), `world_view/3`,
  `entity_scene(Space, …)`, `space_simulation_domain/4` and
  `space_interior_boundary/2` defaults, `eidolon(space_contents, …)` leave for
  `quod:space` (Yan, 2026-11-08). `client_world_view/4`,
  `client_space_selection/3` and `scene_vocabulary/2` stay and call
  `quod:space` through `::` for the projection. Only `isa(ontology,
  quod:space:space)` stays, because the `ontology` class is declared there.
- `gui_forms.pl`: compile an operation form at the recipe owner.
- `quod_client_view.erl`: `navigation`, `controller_preferences`,
  `hud_commands` goal shapes point at the owner recipes.
- Godot client: `class_ref(quod:space, SA, space)` creation subject from the
  pies; qualified class names in the operations panel; Phase 0 allowance.

Production delta: −1,934 pasted lines per user ontology; the four files'
contents move to their owners once; `space_travel/5`, the constructor body, the
digest machinery and the `account_*` check rules are deleted. Exact numbers at
implementation.

## 5. Phase 2 — icon bytes in `quod:gui`

`quod:gui` holds `gui_asset(Digest, Mime, Bytes)` for each icon (36 facts,
100,690 bytes), `gui_query(gui_asset(_, _, _))` admits the read, `gui_icon/2`
names `image(asset(Digest, Mime), resources(Transfer, Pixels))`. The client
asks `quod:gui::gui_asset(Digest, Mime, Bytes)` once per digest through the
existing signed read, verifies the SHA-256, caches by digest. A renamed or
redrawn icon is one `quod:gui` commit; every view that read `gui_icon/2`
refreshes through the existing installed-change path. `/assets/icons/` leaves
the node image. Authoring: a signed execute `assertz(gui_asset(D, M, <<…>>))`
per icon under the node's root authority, not the text editor; the live release
tooling (`quod_source_release.erl`) gains a `terms` step. Material admission is
the existing `material_policy.pl` selection.

## 6. Tests (existing signed seams only)

- `test/quod_lifecycle_single_path_tests.erl`: `quod:user` founded without
  `Frozen` or `user_source_directory`; `m1a_signup` asserts terms only;
  `m1a_setup` through the `setup` form; `m2_spaces` keeps the `-52000` pose,
  foreign storage, destination denial, rollback and recovery; the
  `space_source_digest` case is deleted; `m3a_travel` through `goal(inside(…))`; restart and
  receipts unchanged.
- `test/quod_space_creation_tests.erl`: the `creation-space-template` ontology
  and `Recipe` terms go; storage and destination hold facts and ACL; new cases:
  a body at the owner refuses, class default plus storing-ontology ACL, a
  just-asserted instance placed by its class policy in the same transaction,
  `goal(inside)` idempotent when already inside, `goal(unplaced)` prerequisite
  chaining, a plain local class name follows nothing.
- `test/quod_space_tests.erl`: the transitions as actions; same assertions.
- `quod_gui_operations_tests`, `quod_gui_menu_tests`, `quod_gui_hud_tests`,
  `quod_gui_question_tests`: forms compiled at the owner, pies for
  `class_ref(quod:space, SA, space)`, HUD and question rules at `quod:gui`
  writing through `::` into the agent's ontology under its ACL.
- Constructor fixtures (`test/fixtures/constructors.pl`,
  `class-permissions.pl`): class read at owner.
- Permission frames: `can_invoke/4`, custody and verdict re-proofs still fail
  on any following; only the operation guard follows, and only for a qualified
  class.
- Client: `client/godot-tests` allowance parsing and asset shape;
  `client/godot/tests/ExportLifecycle.cs` headless journeys against a Phase 1
  node; `test/gui-stage1-browser.mjs`.

## 7. Deployment

- Phases 0 and 2: live transaction path, one evidence directory per release
  under `doc/evidence/live-ontology-release-<version>-<date>/`, the 0.7.282
  tooling plus a `terms` step, `live-verify.erl` read-backs, client export to
  `~/Games/quod` behind the launcher. Patch bump only.
- Phase 1: the engine and shared-file changes need the cold coordinated
  release of `system-ontology-acls.md` "Retained-history activation": stop,
  upgrade the image, start, then live-edit `quod:space`, `quod:gui`,
  `quod:agent`, `quod:user` in one atomic multi-ontology transaction including
  the deletions, read back every changed definition, run the §6 probes. No
  refound; root's catalogue is unchanged. Existing users' ontologies are left as
  they are; those users sign up again.
- Commit only when told; one patch digit per commit.

## 8. Decided 2026-11-08

- Creation is `assert(instance_of(quod:space:space, B))` in the storing
  ontology; the class is read at `quod:space`; slots stored with the instance.
- Placement, travel and display membership are `quod:space::goal(inside(…))`,
  `goal(unplaced(…))`, `goal(shown_in(…))`; prerequisites fill in what the
  caller omits; the actions write through `::` under the storing ontologies'
  ACLs.
- Instances are asserted and placed in the same transaction; a just-asserted
  instance is checked by its class policy, as inside a constructor today.
  Constructors build nothing; parts are asserted like any instance.
- The guard reaches the owner's class ACL through ordinary following, the way
  `isa/2` already does; two `no_follow` lines and the guard's frame change.
- The space display rules still baked in `common_predicates.pl`
  (`space_instance/2`, `space_contains/2`, the contents projection,
  `world_view/3`) move to `quod:space` as well; only `isa(ontology,
  quod:space:space)` stays baked, because `ontology` is declared there.
- The two hosting derivation clauses stay in each hosting ontology (resource
  selection forbids scope calls).
- Class rules live at their owners and write through `::`; nothing is pasted
  and nothing new is baked. The two hosting derivation clauses stay in the
  hosting ontology because the spec forbids scope calls in resource selection.
- The user's ontology holds facts, ACL clauses, per-instance ACL facts and its
  agent's one reaction, all written at signup by `quod:user`.
- Icon bytes by signed read. Forms live at the class owner; their goals run
  where submitted. Existing users sign up again. No follow-ups.

Numbers above that were not chosen here: 2 m and the half-depth (Yan,
2026-11-07), 8 pending questions and 12 HUD wedges (already authored), 36 icons
and 100,690 bytes (measured), 1,934 pasted lines (counted). No new limit.


**Signup terms implemented; creation mismatch:** signup now returns the authored
facts, seven pins, local ACL clauses, one reaction and the two hosting
derivations as terms. The superseded user source and old class checks are
removed. The migrated regression passes 53 tests (exit 0,
`owned-signup-regression-01.log`); the signed exact-options policy test passes
(exit 0, `owned-signup-terms-01.log`). Extending that test to the real creation
validator fails (exit 1, `owned-signup-terms-02.log`): `{error,invalid_arguments}`.
Creation currently rejects all variables, including those inside authored ACL
clauses and reactions. Its staging check repeats that restriction. No fix to
those creation-engine checks has been written; work pauses under Yan's explicit
code/plan-mismatch instruction. Signup and the full phase remain incomplete.
The proposed existing-owner correction, retained output and measured partial
delta are in the [signup report](../../doc/evidence/ontology-references-phase1-20261109/signup-terms-stage.md).

Yan approved fixing the existing creation checks on 2026-11-09. Implementation
resumes with variables inside authored clauses treated as clause data; creation
names and other options, exact policy approval, material admission and atomic
creation remain checked. No new path, process or encoding is authorized.


**Signup and creation correction implemented:** the existing creation checks
accept clause variables inside a fixed terms list, while names, remaining
options and postconditions stay fixed. The request handle compares the complete
authored request modulo variable names and symbol representation; changed
values or variable aliases remain different requests. Preparation still compiles
once after policy approval and freezes the same genesis for recovery. Exact
signup policy rejects changed or omitted terms and extra source files.
Signed creation passes (exit 0, `owned-creation-terms-04.log`); journal restart,
root entry, failed-policy and false-postcondition checks pass four tests (exit
0, `owned-creation-recovery-01.log`). The real signup and setup journey passes
(exit 0, `owned-signup-setup-01.log`), including rollback with hosting permission
withdrawn, terms-only source, the class-owned setup form, hosting, first-space
placement, navigation, rendering-pin refusal and original-result recovery.
`owned-signup-lifecycle-06.log` also passes the signup-only journey.
The retained failures cover test variable formatting, missing fixture auth,
root's exact entry shape, a stale evidence field, runtime identity queries in
strict local enrollment/signup ACLs, and variable renumbering across the
creation-policy call. Admission now uses the supplied ACL identity; operation
bodies still verify the exact ontology identity. Temporary diagnostics are
removed. The combined regression passes 96 tests (exit 0,
`owned-creation-combined-01.log`). The expanded signup/setup journey also passes
(exit 0, `owned-signup-setup-03.log`), including withdrawn class permissions,
staged removal of a denial and rollback after a refused final acknowledgement.
The user-owner and foreign form deliverables are checked; remaining space/hosting callers, fixtures,
normative documentation and full phase gates are still unfinished.


**Physical startup callers migrated:** physics, lobby and world-library hosting
use the agent owner; placement uses the space owner's desired-state action.
Lobby and voxel-world ancestry now names the space owner, and lobby physical
admission remains its instances' ACL. Runtime eligibility reads local membership
with ordinary qualified ancestry; source geometry export reads its existing
committed assignment, avoiding unnecessary callbacks into private source state.
Identifier validation is called at the agent owner by physics, hinged motion
and FIPA. The real physical startup journey passes (exit 0,
`owned-physical-startup-06.log`), including preparation without repeated I/O,
atomic placement, activation, rendering, native safety checks and live geometry
updates without replacing the installation. Runs 01–05 retain the missing
private-read permission from redundant callbacks, strict-ACL runtime identity
calls, and remaining local validator calls. Diagnostic tracing is removed.
Broader space/hosting fixtures, documentation and full phase gates remain open.


**Space creation and actions migrated:** the storing fixtures no longer paste
space behavior or publish a template digest. Signed creation uses qualified
membership and explicit desired-state placement, including foreign existing
occupants. Travel, display membership, distinct-owner ACLs, concurrency,
rollback, retained views and restart recovery now use the space owner.
`owned-space-combined-01.log` passes 42 tests (exit 0), including the committed
class-permission suite and physical startup. The first two creation runs and
first action run retain fixture failures. `owned-space-pose-01.log` (exit 1)
reproduces a placement defect: retracting a newly staged default pose inside
`findall` restored it on backtracking, leaving two pose values. Placement now
reads the old slot and replaces it outside enumeration; the regression passes.
Tests for deleted constructor parts and revision-bearing helper entry points
are replaced by explicit atomic occupant placement, desired-state idempotence
and the existing concurrent-proof conflict checks. GUI fixtures, broader
hosting/physics callers, documentation and full phase gates remain incomplete.


**Space forms and menus validated:** the class recipe resolves qualified names
through their actual ontology identity. Menu subjects point at the class owner,
while form discovery retains the selected storing ontology. Storing fixtures no
longer paste space rules; the generic operation fixture defines a local subclass
that inherits the real space class. `owned-gui-forms-03.log` passes all 19 tests
(exit 0): exact geometry, foreign storage, output aliases, stale forms, committed
ACLs, retained outcomes, class pies and live views. The space-owner checklist item
is complete; remaining caller migration and the full phase gates are not.
Stage1 runs 01–03 retain missing forms, qualified-name resolution and fixture
failures. Combined run 01 was force-stopped while EUnit formatted a failure and
consumed 77.5% of host memory: true child exit −9, wrapper exit 247. Its log remains
intact. Run 02 retains the final outdated recipe argument (exit 1, 19 tests, one
failure); test diagnostics now summarize failures without expanding signed
request evidence. The normative proof document is being updated with Yan's
decided-by annotations; the other required docs and cold-release preparation
remain open.


**Hosting callers validated:** the real `quod:agent` owner is founded once by
the shared fixture. Callers use exact agent references; storing ontologies retain
their facts and ACLs. Native observation goals, authored node delegation and
recovery calls now agree on the owner-qualified shape.
`owned-hosting-callers-03.log` passes all 43 tests (exit 0), including custody,
concurrent recovery, observation during restoration, original request deadlines,
worker teardown, FIPA atomic consequences, graceful/abrupt physical loss and
host activation. Run 01 retains 34 failures in 67 tests, caused by setup callback
ACLs; run 02 retains six failures in 43 tests from stale fixture validators,
cursor checks and goal shapes. The hosting checklist item is complete. Remaining
physics and lifecycle fixture migration, docs, release preparation and clean
phase gates are still open.
