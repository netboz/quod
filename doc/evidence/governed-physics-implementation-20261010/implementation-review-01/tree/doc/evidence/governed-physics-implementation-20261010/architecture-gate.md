# Checked plan review and architecture gate

The requested [Fable plan review](plan-review-02/fable-review.md) used
`claude-fable-5-1`, returned exit 0 and changed no frozen inputs. It judged
[plan-01.md](plan-01.md) not ready for server implementation. The earlier
attempt ended with DNS `ENOTFOUND`; its files remain in `plan-review-01`.

Independent inspection confirms the immutable founding-manifest rule, local-only
resource selection, absent foreign-resource invalidation and two-scope/all-body
view restrictions. The existing-owner baseline passed 166 tests, zero failures,
true child exit 0; see `baseline-01.log` and `baseline-01-exit.json`. These are
baseline tests, not acceptance of a new physics implementation.

## Corrections accepted before implementation

The space owner retains admission policy. A simulation domain owns the body
admission consequence, hosted authority, control grants, native resource budget,
run/custody and checkpoints. The phrase implying that the domain owns space
admission in plan-01 is superseded by this distinction.

Body identity allocation belongs to Prolog at the simulation domain, with a
monotonic counter retained after deletion. The unsigned-64-bit exhaustion is an
encoding constraint, distinct from population/geometry allowances. IDs are never
recycled. Concurrent admissions share the existing per-predicate conflict.

Extract shared Prolog shape/pose validation before admitting bodies: solids,
convex hulls, rigid compounds and fixed triangle surfaces. Native positive-volume,
numeric representation and supported-joint checks remain adapter obligations.
A failed foreign dependency pauses its affected world; it must not stop another
independent valid world's owner. Malformed unidentifiable configuration still
fails explicitly rather than being silently dropped.

Control revocation needs an explicit authorized transition and a typed revoked
control status in the view, retaining binding epochs and original-operation
custody. Denial must not unbind a controlled body into observer travel.

The ordinary signed projection must expose the proof's actual per-scope read
heights/dependencies, including failure and disabled selections. Subscribe to
discovered scopes, then obtain and compare current installed snapshots with
those proof versions before accepting the projection. A mismatch refreshes
under the original deadline. Authored dependency lists alone are insufficient.
This extends the existing view owner; it adds no propagation protocol.

## Foreign projection contract proposed for ratification

The source owner explicitly grants installation through committed Prolog
delegation, bound to the exact instance, simulation domain and authority:

```prolog
physics_definition_delegate(Instance, DomainRef, AuthorityRef, AssignmentRevision).
physics_definition_projection(DomainRef, AuthorityRef, Instance,
                              DefinitionRevision, Definition).
```

The second predicate checks that source-owned delegation and reads the source's
current definition. It runs as a pure read of that source's verified committed
snapshot. It does not impersonate `current_principal/1`, call a foreign scope,
perform I/O, grant user invocation, or act as an arbitrary permission oracle.
Admission/edit/withdrawal remain ordinary signed proofs subject to every
participant's `can_invoke/4` and domain policy. This is an explicit installed
resource-delegation contract, not an exemption from signed invocation policy.

The existing runtime supplies its exact installed domain/authority and current
host epoch/key from the local policy selection. It may consume the source's
projection only for that hosted authority. The foreign-log owner verifies the
runtime's caller-owned retained follow and its incarnation before granting a
selection handle to that runtime's bounded resource runner. A caller-supplied
principal without this ownership is insufficient.

The narrow interface is a definition selection bound to follow, source identity,
materializer generation, authority and original deadline. Its result contains a
bounded immutable definition, source height/projection ID, definition revision,
geometry digest and observed predicate dependencies. It returns explicit
building/stale/unavailable/denied failures. It exposes neither raw source clauses
nor an arbitrary external goal API.

The evaluator must not run an unbounded proof in the materializer's receive loop,
as the review's literal `select/4` sketch could do. Reuse the existing killable
resource runner with an owner-issued MVCC snapshot handle and its retained floor,
or an equivalent bounded worker owned by the existing materializer. Handle
lifetime, cancellation and source replacement invalidate results. No new
registered process, broker, replay engine or synchronization service is proposed.
The runtime retains immutable selected results/revision references for the
consumer lifetime, without a second mutable geometry database.

The runtime records source observation keys with its current resource basis.
Every authenticated source readiness/advance/resnapshot/withdrawal notice checks
that basis independently of reaction publication, and queues only affected
selection. Source changes racing selection are fenced at `resource_selected`
before installation. Duplicate/unchanged checks cause no selection, rebuild,
write or sync. Restore current verified state after recovery; historical
reactions are never needed to repair bodies.

Live bindings name the original anchored instance and exact current source
revision. The governed source geometry-edit action automatically invokes the
space/domain consequence in the same existing atomic proof: body/structure
revision, checkpoint invalidation and incompatible activity cleanup advance
together. No manual re-adoption occurs. The bound revision is an OCC/install
fence for that transition, not a deliberately pinned reusable recipe.
A raw administrative source edit that violates this revision contract cannot
install changed geometry under an unchanged body fence; it reports invalid
configuration. Normal authorized physical edits must exercise the governed
atomic action and install automatically through the retained subscription.

## Ownership choice requiring the task's architecture gate

For an existing lobby without physics in its immutable manifest, the bounded
candidate leaves the space, appearance and live geometry at their existing
owners, and normally founds a domain owning the physics authority's separate
hosting/control/run/checkpoint lifecycle. Its manifest is fixed at genesis.
It is an association to the same visible world, not a new lobby or replacement
identity. Several spaces can share that domain. Co-location uses this same
reference/ownership contract when the owner already has the capabilities;
there is no permanent old/new compatibility branch.

The alternative keeps all those physics truths at the existing lobby owner.
If its manifest lacks physics, that requires a new root-governed effective
capability installation/activation contract while preserving immutable founding
provenance. The pinned actor architecture and this task require that foundational
gap to pass an architecture gate; the removed mutable-module experiment cannot
be revived as its implementation.

The reviewer also suggested changing future lobby founding templates. That does
not identify or enable an existing personal lobby and is not a substitute for
this task's acceptance target. No automatic new lobby/account is authorized.
First identify the actual current signed personal lobby; a freshly capable
existing scope might make the capability question unnecessary. The missing
signed session is evidence access, not proof that the personal lobby is absent.

Ratification here authorizes local implementation and tests of the selected
contracts only. Deployment, live founding/hosting/link/body writes, refounding
and ledger changes remain under the existing release authority. The requested
second Fable review follows an implemented, tested, frozen tree. This tracker
stays open until its remote-change measurements and real signed normal-view
desktop acceptance in the same preserved lobby are verified.

Production code changed in this session: zero lines. Existing user-owned changes
were preserved. New files are this task's plan, frozen review inputs, reports
and baseline evidence.
