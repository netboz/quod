# Phase 1 cold coordinated release preparation

This is preparation only. No deployment, refound, live edit, commit or version
bump has been performed. Local qualification is recorded in the
[Phase 1 report](phase1-report.md); the complete EUnit gate still fails on the
excluded browser driver. Activation remains pending Yan’s explicit go. Phase 2
icon storage is excluded.

Candidate source: `worktree/pearl-stone`, based on
`7e6809e46ea290a53ffff910a53e0386d75b966f` (0.7.282). The phase baseline is
`before.patch`; subsequent working changes and their evidence remain uncommitted.
The phase report freezes the exact candidate diff, input hashes and local built
artifact hashes after the required gates. The final export excludes the existing
output directory, and the package-content check confirms its absence. A patch-only
version bump remains separate and requires Yan's instruction.

## Existing activation procedure

Use the [retained-history activation procedure](../../system-ontology-acls.md#retained-history-activation)
and existing source-release compiler, atomic transaction, readback and outcome
resolution. No proof or validator may span incompatible engine/common artifacts.
Do not infer permission to refound from the absence of compatibility code.
Yan has accepted eventual fresh signup and refounding, but executing a refound
still requires his explicit go. Preserve existing ledgers, keys and uncertain
operations until the authorized activation procedure says otherwise.

The coordinated artifact contains the committed-policy frame, qualified slot
initialization and creation context changes; terms-only founding validation;
signed owner reads and precise read dependencies; native signing and presentation
callers; and the corresponding common Prolog and client callers. All participating
nodes must use the same candidate artifact before source activation.

The source transition replaces the complete reviewed definitions at
`quod:space`, `quod:gui`, `quod:agent` and `quod:user` together, including removals,
through one existing atomic multi-ontology transaction. The root catalogue
identities are unchanged. The reviewed node, physical, lobby, FIPA and voxel
source callers must match the candidate where those compositions are installed.
The old user's ontology is not repaired or silently rewritten; users sign up
again under the new terms-only creation policy.

## Preparing the existing source edits

The 0.7.282 operator module `quod_source_release` already provides `plan/3`
and `apply/4` with `DryRun = true`. Use those compiler calls to obtain the
exact-baseline target goals. Its `release/4` executor applies predicates
separately and therefore does not execute this Phase 1 transition. Collect
all returned target goals in one ordinary `transaction/1` conjunction before
any authorized signing or submission.

The source inputs are `quod_space.pl`, `quod_gui.pl`, `quod_agent.pl` and
`quod_user.pl`, with their inspected stored definitions as baselines. Retain
other authored clauses and target-specific ACLs. Source-file comparison alone
cannot remove facts injected at founding: inspect `space_template_hash/1` at
`quod:space` and `user_source_directory/1`, `user_source_component/2` and
`space_source_digest/1` at `quod:user`, and compile their complete removal in
that same transaction. Keep the existing seven vocabulary pins and root
catalogue identities. Inspect the installed node, physics, lobby, FIPA and
voxel compositions for the corresponding changed callers and include their
reviewed source edits where present.

For each edit, retain namespace, anchor, canonical baseline, canonical draft
and the compiler-returned goal. Refuse a changed baseline; the old operator
module's per-predicate apply loop and source-component re-pinning are not the
Phase 1 submission. Readback uses the same exact target and full changed
predicate source, including an empty source for every removed definition.
The ordinary source-editor tests exercise compilation and readback against
local test histories; no live maintenance baseline has been inspected in this
phase, so no fleet-specific compiled or signed request is claimed here.

## Evidence required before an activation go

- Freeze the exact candidate and run clean sequential EUnit, CT, Dialyzer, xref
  and client gates with full logs and actual child exits. Report the previously
  excluded browser adapter failure separately; do not label that gate clean.
- Record the built runtime/package hashes and client artifacts, and the exact
  source definitions and target namespace/anchor baselines inspected under the
  existing maintenance authority. Keep private source and keys out of public
  evidence. Compile the complete before/after source delta with the existing
  source compiler and retain it for review.
- Retain the exact signed activation request, signature and operation identity
  when the operator authorizes its preparation. An uncertain result is resolved
  through existing outcome lookup; it is never resubmitted under a fresh ID.
- After authorized activation and certified application, read back every changed
  definition. Run qualified creation, setup, placement/travel, committed ACL,
  private-source, wrong-anchor, HUD/question, hosting/custody and physical
  admission probes through the existing signed interfaces.
- Restart the authorized retained state, resolve pending atomic obligations and
  repeat the probes. Verify that unchanged reads neither replay history nor
  rebuild, write or sync state, and that actual source updates reach retained
  consumers, before reopening traffic.

Until those artifacts and checks are complete, this file grants no operational
step and reports no successful release.
