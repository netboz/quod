# Automatic live collider updates: local implementation evidence

Tracker `task_1791574097686_paoo8v` remains open. This stage implements the
[approved live-collider plan](live-collider-plan-01.md) against baseline
`4631578cd74ac63f907df1288ec74d96115b36fc`. It has not been deployed. No server,
personal-world history, founding manifest or release label was changed.

## Result and ownership

The source ontology owns its geometry, definition revision, exclusive space
assignment and installation delegation. The destination owns its admitted
body identity, authored placement and structure revision. Admission, a source
edit and withdrawal each compose their counterpart changes in the existing
signed atomic transaction. Receiver denial rolls back the source change.

The existing runtime subscription receives the committed source change. Its
retained verified projection supplies the shape to the current resource worker;
the existing native owner installs it. There is no additional broker, geometry
database, polling loop, post-commit repair, or reaction-history replay.

The sole authored body relation is now `physics_body_definition/6`, with either
`owned(Shape,Density)` or an anchored live reference carrying assignment and
definition revisions plus a canonical digest. The superseded `physics_body/7`
relation and its callers were replaced. A Prolog monotonic allocator prevents
body ID reuse; population/geometry allowances remain authored Prolog policy.

The destination explicitly composes `physics_space_change/3` through the
existing space hook. Its source subscription must be a stored ground fact.
Definition refresh has its own narrow destination policy grant. Ordinary
viewers and controllers do not need permission to read source geometry.
Repositioning a live body deliberately revalidates that geometry and therefore
requires the editor's source entry grants. World-local geometry uses owned
definitions; this stage's live-reference admission uses another ontology.

Source failures pause only dependent worlds, keeping their colliders present
but unavailable. A temporary source advance retains input/view registrations;
an unrelated verified delta resumes without rebuilding geometry. A relevant
change, revocation or source loss invalidates the normal view/control path.
Other valid worlds retain their native owners and state.

Ready notices now carry their retained reader reference. Selection does not
synchronously ask the shared foreign-log owner for metadata. Fences cover the
follow, source identity, height/projection, reader incarnation, original
deadline, assignment, definition digest/revision, body revision and world
structure. Source predicate dependencies are scoped to the consuming world.
Local invalidation and OCC retain their existing conservative/per-predicate
precision; this is not row-level OCC.

Loss of an established projection reader rebuilds current verified state
through the existing foreign-log lifecycle. A reader that fails before
publishing verified state parks until source progress instead of entering a
restart loop. Recovery requires no missed reaction publications. Authority
replacement changes its source delegations in the same atomic transition,
using the existing hosting, custody and run-generation lifecycle.

## Verification

The final scoped regression ran sequentially against an unchanged tree:
[456 tests, zero failures](live-collider-regression-05.log),
[true exit and before/after source hashes](live-collider-regression-05-exit.json).
The [final source manifest](live-collider-final-source-manifest.json) identifies
the checked implementation and its two post-review static-analysis corrections.
It covers physics, control, space, common primitives, resource basis, runtime,
foreign projection/log and directory-control owners. Cross-reference checking
also passed with [exit 0](live-collider-xref-01-exit.json).

Production-owner tests exercise:

- Two distinct non-lobby source/destination pairs; signed atomic admission,
  shape edit, withdrawal, deletion/recreation and fresh body IDs. A real local
  committed source edit changes a native clearance result from clear to
  occupied through the retained verified subscription.
- Prepared admission versus admission and edit versus withdrawal, producing
  one commit and one OCC conflict. Narrow receiver denial rolls back both
  participants. Nonphysical admission and derived-only subscriptions fail.
- Existing generic world-policy coverage still verifies different ontologies
  with gravity -9.8 and -1.62 m/s² and different body-read ACLs. Changing the
  instance gravity replaces the run while preserving its world identity.
- Stale selection delivery, exact source grant revocation/restoration,
  retained-reader replacement, foreign-log owner replacement and atomic
  authority redelegation, without reaction replay.
- A suspended shared foreign-log owner does not block an unchanged selection
  using its retained reader. Pending native notices coalesce while the native
  owner is suspended.
- A real signed `/api/simulation` session whose viewer has no source grants
  opens and controls a live body. An unrelated source commit retains the view;
  an authorized geometry edit refreshes it through the normal protocol.
- Two independently hosted world identities in one ontology: source failure
  pauses the live-source world while the owned-geometry world's PID,
  incarnation, geometry-install count, steps and tick remain unchanged.
- Moving-door contact against the live collider reaches the existing
  authenticated observation/consequence path. This is local fixture evidence,
  not durable real-personal-world door acceptance.

Twenty unchanged resource reconciliations traced zero calls to projection
creation/application, native world/geometry/hinge installation, ledger
open/fold, and file write/pwrite/sync/datasync. Native installation, step and
tick counters and incarnation also stayed unchanged. This measurement uses a
settled zero-gravity fixture; it does not count legitimate simulation stepping
or actual durable updates as redundant work. The source-edit tests separately
show that real updates still install. No remote work-cost claim follows from
these local measurements.

## Failed runs and their disposition

All original logs and exit receipts remain under this directory; corrected
runs have separate labels. No failed campaign was overwritten.

| Campaign | Observed failure | Correction and evidence |
| --- | --- | --- |
| `base-01` | Prolog parser error from an extra closing parenthesis; 83 failed tests | Corrected syntax; subsequent owner and regression runs parse the production ontology |
| `base-02` | Unbounded pending owner notices | Separate bounded pause/invalidation notices with existing acknowledgements; `owner-01` and final regression pass |
| `owner-02` | Test resumed a process from the wrong suspending owner | Resume through the runtime that suspended it; `owner-03` passes |
| `owner-05` | Test installed a sys callback without its state tuple | Correct callback registration; later controls/recovery tests pass |
| `owner-06` | Test compared an input before its completed notification | Await the actual completion; `owner-07` passes |
| `regression-01` | Four failures: recovery query omitted incarnation; temporary projection-handle tuple broke a directory test; two fixtures observed state before delivery/installation | Exact query fence and delivery barriers corrected. Original projection-handle API restored; no compatibility branch. `regression-02`: 451/0 |
| `shared-owner-01` | Production selection timed out on the shared foreign-log metadata lookup and remained paused without a wake | Reader reference carried by existing verified notices; no synchronous lookup. `shared-owner-02`: 5/0 |
| `regression-03` | Established reader death remained building indefinitely; an opening-cancellation fixture raced successful proof completion | Existing projection-down lifecycle now rebuilds established readers. Cancellation uses an actual proof barrier. `owner-09`: 4/0 |
| `client-01` | Test removed the editor's source grant as well as the viewer's | Distinct signed editor/viewer principals. `client-02`: 1/0; full regression also passes |
| `dialyzer-01` | Two unmatched-return warnings: the new guard increment and a pre-existing signed-view cleanup expression | Use the return-free atomic increment and explicitly discard cleanup results; `dialyzer-02` passes and `regression-05`: 456/0 |

The earlier `owners-geometry-02` unattributed datasync failure remains recorded
in the main evidence index. These successful measurements do not retroactively
explain that historical event or establish remote unchanged-work acceptance.

## Review

[Fable review 01](live-collider-review-01/fable-review.md) identified input
continuity, unnecessary shape reads, missing authority replacement and overly
broad refresh authorization. Each was corrected and tested.

[Fable review 02](live-collider-review-02/fable-review.md) found the shared-owner
timeout and redundant source reads in the signed view. Both were reproduced or
covered at the production seam and corrected. Its optional singleton-admission
and unsimulated-definition-edit findings were also addressed. The final design
keeps source geometry dependencies at the physics resource owner and uses its
existing invalidation/installed notices; signed view dependencies still govern
the visible world, acting agent, selected physics and actual view/control ACLs.

[Fable review 03](live-collider-review-03/fable-review.md) found no remaining
correctness, authorization or integration blocker in the corrected delta.
Its [receipt](live-collider-review-03/receipt.json) records a successful
`claude-fable-5-1` invocation and 30 unchanged frozen files. The two subsequent
[ignored-return corrections](live-collider-post-review-static-fixes.patch)
were independently checked: the guard increment discards its result as before,
and signed-view cleanup explicitly ignores its returned list. They do not
alter the reviewed fencing or source propagation design. Final static analysis
passes with [exit 0](live-collider-dialyzer-02-exit.json).

Two conservative behaviors remain: a separate local reselect during source
rebuild can refresh an existing view, and a multi-page source resnapshot
reselects even when its eventual changes are irrelevant. Neither admits stale
geometry or changes the unchanged-check measurement above. These are retained
limitations, not precision claims or hidden fallback behavior.

## Scope and remaining acceptance

Production changes are +557/-99 lines, net +458, across seven existing files.
The increase supplies the Prolog lifecycle/authorization contract and extends
the existing resource owner with source dependencies and per-world fencing.
No new production module, process owner or compatibility implementation was
introduced. Tests and retained review evidence are excluded from this count.

This is local implementation evidence. Release-wide clean gates and compatible
validator rollout through the existing single release/server writer remain
separate from these affected-owner checks. The current package does not change
any retained world's authored source or founding provenance automatically.

Still required for this tracker: a real remote committed collider change and
work measurements; a fresh signed current personal-world identity/history
baseline; and real desktop collision acceptance in that same world with its
console, openings and history preserved. Browser MCP listed no active signed
session during this stage. No old or system-vocabulary anchor was substituted,
and no new personal world was created. Vive/WebXR and durable real-world door
consequence acceptance remain separate work.
