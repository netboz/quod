Yan explicitly requested Claude review first of the governed-physics plan and
second of its implementation. Use Fable. This is the second review, of the
actual partial implementation now present, not an implemented feature claim.

Review only this frozen read-only tree and adjacent ../changes.patch,
../before/ and ../source-manifest.json. Do not modify anything, execute commands,
use network tools, inspect credentials or read unrelated workspace files.

Read AGENTS.md, doc/world.md and doc/multiwrite-architecture.md before assessing
semantics. Read the task's implementation-geometry-01.md and architecture-gate.md
under doc/evidence/governed-physics-implementation-20261010. The full proposed
plan-01.md is there for context, but its ownership/delegation architecture gate
is still pending and none of those domain/subscription/view paths was changed.

The actual patch changes priv/ontologies/quod_physics.pl, its production-owner
tests and doc/physics-native.md. It replaces physics_valid_body/5 with shared
physics_valid_body/6, wires generic body relocation and both door edit actions
to it, supports all existing native shape schemas and keeps the box-only native
hinge restriction explicit. Net production growth is 37 lines; tests add 60.
Check all callers, native geometry and hinge encoding in
src/quod_physics.erl, native/quod_physics/src/geometry.rs and lib.rs. No new
bridge, process, mutable store, manifest or projection protocol is proposed.

Validation: focused 7 tests passed; four production-owner modules passed 173
tests with true child exit 0 and unchanged source hashes. Receipts are frozen
here. The earlier rejection fixture setup used unsupported retractall/1 and
failed; the corrected labelled run uses existing retract/1. All failed evidence
and that fixture are retained. Do not repeat tests or claim these fixtures are
the same current signed personal lobby, a remote collider change or full
acceptance. The real signed baseline is unavailable and the task remains open.

Prioritize concrete defects in this implemented slice: Prolog ground/schema
validation, units, coordinate and encoding envelopes, native supported shapes,
rotation preservation, density, fixed-only surfaces, explicit openings, policy
and atomic rollback, failure/cut behavior and meaningful test coverage. Assess
whether the shared validator is actually reused without a second domain engine
or compatibility path. Distinguish schema guards from native numeric/volume
checks; do not require a duplicate hull/collision engine in Prolog.

Return findings ordered by severity with exact frozen file/line references,
causal explanation and fixes. Then give a limited verdict on this geometry
prerequisite and name remaining full-feature gates. Independently verified code
and acceptance still belong to the parent; your review is consultative.
