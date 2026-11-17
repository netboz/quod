# Checked final M3a Claude consultation

This is a subsequent review addition, outside the immutable M3a implementation
boundary. Yan explicitly requested this read-only final consultation after the
server checkpoint was frozen and independently accepted. The frozen source and
all prior evidence remain unchanged. This note records a newly identified open
defect; it does not turn passing gates06 into evidence for its untested trigger.

The reviewer was the existing session ca58432f-ea5c-4d98-aeeb-c92a8e6a120b,
provider claude-code, model claude-code:fable, capability scope read. The installed
API reports it idle with no edited files or error. It had no write_file or
run_command capability. It performed no builds or tests. Its wording about
reading a git diff refers to supplied patch/source reads, not a command run.
The exact response is retained in [claude-review.md](claude-review.md).

Parent checker: 8d55a3f3-e558-46e2-afbb-2e028558f371. Check performed on
2026-10-28 against branch worktree/pearl-stone, HEAD
69196a36caeeb06e6ee07982f1ab1988d7c16b43. The scope hash check and actual
binary patch equality are recorded in [input-verification.json](input-verification.json).

## 1. Confirmed by independent source tracing: frame failure aborts owner reconciliation

Severity: medium availability defect. No authority bypass or unsafe continued
simulation was established. No new runtime reproduction has been run.

At [quod_runtime.erl:2860](/home/yan/src/quod_worktrees/pearl-stone/src/quod_runtime.erl:2860),
a retained frame export that fails to resolve throws
resource_selection_failed/source_frame_unavailable. A missing required exact
frame-member row can also throw through the same path. The direct caller
resolve_physics_body does not convert the result into a body failure.
The fold at :2767 therefore never returns its per-world accepted/unavailable
lists. The outer capture at :2926 converts the throw into an error for the
entire physics_worlds resource; install_resource(:3049) returns it without
calling project_physics. The existing per-world preservation/resume path at
:279-309 is bypassed.

Concrete trigger: with a shared framed body and another installed independent
world in the same runtime, an authorized local source edit invalidates an
admitted frame's definition/export while retaining the member row. Local
invalidation at :1034-1039 marks installed worlds pending reconciliation.
The failed frame stops the whole reconciliation, so the unrelated world's
guard is not refreshed and it can remain unavailable. A foreign-only edit
does not necessarily invalidate the unrelated world first; do not claim that
every foreign failure immediately pauses every independent world.

The failure-isolation requirement is at
[godot-foundation-contract.md:355](/home/yan/src/quod_worktrees/pearl-stone/doc/godot-foundation-contract.md:355).
The existing geometry-delegation failure test at
[quod_physics_tests.erl:641](/home/yan/src/quod_worktrees/pearl-stone/test/quod_physics_tests.erl:641)
does not exercise an unresolved retained frame export.

Correction belongs to the existing resource/body/world resolution owner.
Frame/geometry failure must reach the same explicit per-world unavailable
result while retaining observed missing dependencies and continuing other
worlds. Preserve real errors, source fences, deadlines and native identity;
do not add a static pose fallback or another selector. Qualify an actual
two-world retained-frame failure, unchanged unrelated native work, refusal of
affected queries/control, and recovery on a real repaired source update.
This remains open in the frozen implementation.

## 2. Conditional cross-domain decorative-view concern: retain visible refusal

The behavior is confirmed: space_scene_pose at
[quod_space.pl:542](/home/yan/src/quod_worktrees/pearl-stone/priv/ontologies/quod_space.pl:542)
refuses a body belonging to another selected physical domain for physical and
display uses. Required contents can consequently make the outer projection
unavailable. Tests explicitly require this refusal for both roles.

This is the conservative M3a shared-component boundary, not a confirmed new
correctness defect. The contract at :349-350 permits visible refusal for
incompatible independently enabled runs. M3a does not claim arbitrary
multi-domain dynamic decorative rendering. Claude's suggested authored-static
fallback would discard the selected dynamic binding; it is not accepted.
Per-occurrence handling of an incompatible independent domain, if wanted,
requires an explicit later projection design rather than an implicit fallback.
Decorative duplicates within the selected shared component remain covered.

## 3. Root component-admission row: unsupported-policy diagnostic concern

The conditional behavior is confirmed: an authored root
physics_component_admission/5 row can reach an unwrapped transform/6 pose,
which the existing root pose schema refuses as invalid_physics_body.
However, [physics-native.md:138](/home/yan/src/quod_worktrees/pearl-stone/doc/physics-native.md:138)
explicitly restricts this new policy to bodies inside a child and keeps
direct root bodies on physics_admission/4. Root support for the new child
policy is not an M3a acceptance obligation. The valid root path remains
covered. A clearer rejection of an out-of-scope policy row is optional
guard/diagnostic cleanup; empty frame paths or a second root authoring route
will not be added solely to accommodate that row.

## 4. Optional comments checked

The shared geometry schema delegates transform validation to the existing
space_transform/1 owner; duplicating the integer checks would contradict the
one-algorithm rule. No concrete supported composition failure was established.
allowed(query,resource_selection) remains an intentional public class-level
refusal; dispatch's dependency-aware special case is separate. Removing that
guard without tracing all public callers is not justified by the consultation.
The loose direct body_pose depicts validator predates M3a (present at HEAD);
the shared construction path binds exact subject/assignment before producing
that pose. No new reachable subject-authority defect was demonstrated. These
comments do not establish additional blockers or authorize broader cleanup.

## Review limits and checkpoint status

The reviewer identified no finding in shared answer projection/unification,
frame composition, signed travel or mechanics relocation. This is bounded
review, not proof of absence. It did not audit every gui_forms line or re-read
the unchanged Rust adapter. Neither reviewer nor parent ran new tests for this
consultation. Claimed frame-edit/hinge/control and foreign-source-access edges
remain coverage limits until a correction campaign covers them.

Gates06's native56/EUnit4264/CT149/xref/Dialyzer/local release results and the
immutable snapshot are preserved exactly. The newly confirmed isolation defect
needs correction and relevant qualification before it can be represented as
covered. No production/spec/test code, tracker body or status, accepted
coordinator verification, M3b prompt, original handoff or prior snapshot was
edited. Root retains serial implementation-launch ownership; this consultation
does not launch M3b or resume a writer. M3b/full M3 and broader Stage 2 remain open.
