# Governed physics: partial implementation evidence

QUD.27 remains open. This folder records local implementation stages,
not acceptance of the full feature. No server, deployment,
live ledger, account or founding history was changed.

The [system-registration slice](system-registration-slice.md) adds physics
to the existing common startup base, proves separate gravity/permissions in two
world ontologies and records 228 passing owner tests. It also records the exact
source-receipt cause and correction for the newer unchanged-work failures.
Backward compatibility is not required: the extra old-manifest test and release
instructions were removed; no compatibility implementation was added.

The current mixed-scene stage preserves decorative marks, authored parents and
exact body references through the existing pose writer. Claude identified a
shared-schema policy gap; the correction reuses the rendering vocabulary and
extends ordinary recipe construction. See the [review disposition](mixed-view-disposition.md).
The signed-read dependency stage is now implemented through existing proof scopes,
signed result envelopes and socket subscriptions, including retained dependencies
for negative selections. See the [implementation disposition](view-dependency-disposition.md)
for review findings, corrections, failed campaigns and passing validation. The
final socket campaign passed 170 tests with unchanged tracked inputs. Three real
remote protocol cases also passed. These are not remote collider installation or
ordinary desktop acceptance.

The [ordinary-view plan](ordinary-view-plan.md) applies to generic spaces,
using existing space classification and physics policy. Yan requested an
[independent review](self-review-01/review.md) after Claude reached its session
limit; that review replaces the immediate wait for Claude. It corrects the plan's
navigation fencing, cancellable opening, singleton selection and shared physical
eligibility contracts. Implementation corrections preserve exact HTTP revision
values and engine/recovery-run readiness. The 314-test correction campaign and
two final restart checks passed.

The ordinary-view implementation now replaces the separate Simulation menu and
acting-agent physics discovery. See [its independent review and validation](ordinary-view-disposition.md):
181 affected owner tests, 135 final deadline/recovery/result tests, three client
test files and TypeScript validation passed. The MCP WebGL2 fixture passed its
camera, pose, pause and observer checks. Counts overlap; none of this substitutes
for real signed personal-lobby acceptance or remote collider installation.

The retained-projection prerequisite now supports safe concurrent snapshot reads
inside the existing materializer owner. Its production directory caller is
preserved, the obsolete clause-message path is removed, and unchanged reads
perform no measured replay, projection apply or file write/sync. See the
[independent review](projection-readers-disposition.md): 218 affected owner tests
and 30 final focused tests passed, with failed campaigns retained. This is not
the still-missing source-dependency-to-installed-collider wiring.

The [read-only signed-client access probe](signed-baseline-access-01.md) reached a
certificate error and established no personal-lobby identity/history baseline.
No server, account or browser identity storage was changed.

## Implemented and reviewed scope

The shared Prolog authored-body schema supports the adapter's box, ball,
capsule, convex, compound-parts and fixed-surface geometry. It validates body
identity, finite native encoding and Prolog coordinate allowance. Authored
hinges retain the adapter's vector/box restriction and native installation
rejects rotated frame or leaf definitions. Body edits preserve rotation and
revision fencing. Body-specific refusal reasons do not leak into control,
motion query or recovery checks. Local signed tests exercise the installed
production owner; these are explicitly founded fixtures.

The geometry slice's production changes were +71/-13 in Prolog and +2/-0 in
the native adapter, net +60 lines. Common registration adds one production line
and updates the bridge module description. No new process, propagation path or mutable collider
store was introduced. The existing user-owned plan and other sessions' files
were preserved. The changes are uncommitted.

## Claude/Fable review

Yan requested plan review followed by implementation review. Reviews used
`claude-fable-5-1`, read-only tools, no hooks/MCP/commands, frozen inputs,
captured true child exits and checked input hashes. Advice was checked against
the repository before acting on it.

- `plan-review-01` failed DNS resolution and is retained as a failed attempt.
- [Plan review](plan-review-02/fable-review.md): exit 0; 45 unchanged inputs;
  not ready for server implementation.
- [First implementation review](implementation-review-01/fable-review.md):
  exit 0; 52 unchanged inputs; identified hinge and encoding defects, corrected.
- [Capability proposal and follow-up implementation review](implementation-review-02/fable-review.md):
  exit 0; 63 unchanged inputs; capability plan incomplete; identified shared
  coordinate-reason leak, reproduced and corrected.
- [Final partial implementation review](implementation-review-03/fable-review.md):
  exit 0; 17 unchanged inputs; corrected geometry slice accepted for its stated
  scope. Remaining low-severity nits/residuals are recorded in that report.
- [Existing-model reuse audit review](reuse-review-01/fable-review.md): exit 0;
  52 unchanged inputs; validates existing Prolog reuse and withdrawal of the
  mandatory capability-epoch proposal. The [checked disposition](reuse-review-disposition.md)
  records qualifications and rejects the proposed pinned-copy default because
  the task requires live referenced collider updates.
- [Shared-registration implementation review](system-review-02/fable-review.md):
  exit 0; 68 unchanged inputs; no production defect or unused compatibility code.
  Two test/documentation corrections were made and 15 affected tests passed.
  See the [checked disposition](system-review-disposition.md). The first packet
  setup failed before launching Claude and remains recorded as `system-review-01`.
- Signed-read dependency implementation reviews 01 and 02 completed against
  frozen inputs. Review 02 found no blocking defect in its scope. Later corrections
  and the remaining review/test obligations are recorded in the
  [dependency disposition](view-dependency-disposition.md).
- Ordinary-view plan review attempts 01 and 02 received only a session-limit
  error. They are failed invocations, not reviews or approvals.
- Yan then requested Codex's own review. The [independent review](self-review-01/review.md)
  records its findings, corrections, deliberate failing reproductions and local
  verification. It is distinct from all Claude/Fable results.

The review's description of accepting maximum finite rotations "by choice"
is consultative wording, not new user approval. The implemented bound is the
adapter's encoding envelope; Prolog remains responsible for policy limits.

## Validation and unresolved measurement

Every labelled run retains its complete log and child-exit/source-hash receipt.
The final [focused receipt](control-reasons-03-exit.json) records 13 passing
cases; the [broader receipt](owners-geometry-03-exit.json) records 178 passing
tests across physics, control, runtime and space owners. `git diff --check`
passed. Failures and corrections are described in
[the initial handoff](implementation-geometry-01.md),
[the hinge/encoding correction](implementation-geometry-02.md), and
[the refusal correction](implementation-geometry-03.md).

`owners-geometry-02` observed one unattributed `file:datasync/1` during a global
strict unchanged-work check. Its fixture and failed log remain. Later runs
with PID/caller attribution did not reproduce or explain it. The assertion
was not weakened. A [deliberate-sync diagnostic](trace-negative-control-01.erl)
confirmed detection. The cause remains unresolved; passing local checks do not
establish remote unchanged-work acceptance.

## Required architecture gate and remaining acceptance

The [existing-model audit](existing-model-audit.md) corrects the earlier failure
to trace instance attributes, argument-sensitive invocation policy, ordinary
Prolog wrappers and cross-ontology scopes before proposing new machinery.

Source-owned retained-projection delegation was approved. The interactive
question about the [existing-owner capability proposal](existing-owner-capability-gap.md)
was cancelled, not approved. Yan challenged its premise: physics should be a
system interface available at startup, governed by each world's Prolog policy.
The code already has shared registration in `quod_predicates:load/1`, called
by every committed projection's `new_est/0`; physics now uses that common list.
Its registration allocates no simulation. No capability-evolution contract was
needed for this composition. Root's
system-ontology catalogue is discovery, distinct from this shared registration.

The [checked review disposition](capability-review-disposition.md) records the
earlier proposal's missing mechanics. A
[deterministic snapshot diagnostic](registry-snapshot-diagnostic-01.erl) proved
current compiled registration is visible through an older retained MVCC handle;
that rules out naive live loading, not registration in a cold startup base.
No capability-evolution machinery was implemented. The system-interface
correction received the scoped reuse-audit review above; shared registration
is now implemented locally. The historical plan and compatibility diagnostics
are not active requirements.

The fresh signed personal-lobby identity/history baseline was not obtained.
Historical October 9 and system lobby anchors were not substituted. A read-only
LAN endpoint probe reached TLS but failed hostname verification; localhost had
no listener. An isolated headless browser showed an error page and was closed.
No authenticated desktop collision acceptance was performed.

The completed 0.7.256 refound owner's coordination report names candidate job
version 57 and deployment `82d460e6-edcc-49ee-89bc-d9fb3ab77da3`, with no active
server writer, queued release or pending refound. That session performed only
read-only checks with an ephemeral signup principal; it established no personal
lobby baseline. Its [sealed evidence](../hot-controls/deployment-256-refound/README.md)
and reported root/system-vocabulary anchors do not identify the current personal
world. This session has not independently refreshed that server-state report.

Still open: coordinated deployment through the existing release authority; exact source
dependency-to-install wiring through existing subscriptions; generic admission,
withdrawal and concurrent/recovery coverage; generic ordinary-view selection
and control behavior; remote committed collider propagation and work measures;
and real signed desktop acceptance in the same current personal lobby. Separate
Vive/WebXR and durable real-door acceptance are not claimed by these fixtures.
