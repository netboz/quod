# Clear-floor travel: proposed correction for review

Observed: desktop 0.7.262 completes 80.73 seconds and six signed view renewals,
but three held-input pauses coincide with native occupied(1,...) feedback.
The unchanged solver reproduces all three with the exact captured poses,
authored annular surface and quantized ordinary movement. Contact distances
at the initial poses are positive (about 1.7–1.9 mm). The linear shape cast
with the policy's 2 mm target distance returns None, then the endpoint overlap
check correctly refuses the resulting penetration. Direct casts at target
zero find the floor; toggling stop_at_penetration does not fix the 2 mm cast.
The endpoint check must remain. The library is the unmodified locked Parry
0.31.1; cached source matches the .crate archive SHA256
7b626edc0b497dba4bdf6e1e0797895294ed9f61dac2bd28cb5d34d37ad2ca7e.

Proposed bounded plan (no production change yet):
1. Keep policy, authorization, budgets, world geometry and all owner lifecycles
   unchanged. No compatibility, ledger format change, refound or lobby branch.
2. In the existing native linear cast, explicitly recognize a contact already
   within the authored skin before asking the library for a later impact. Use
   its existing contact query and world-space normal; approach produces a
   zero-time contact. A separating contact does not exclude the collider: run
   the ordinary full cast so another face in the same surface remains visible.
   Charge every actual contact and cast query against the existing Prolog
   narrow-phase allowance. Keep the nonlinear rotation path and final overlap
   refusal unless the evidence demonstrates that they also require change.
3. Review whether nearest-contact semantics are sufficient for a mesh corner;
   this is an unresolved correctness question, not an approved fallback. Do not
   accept weaker guarantees or a second uncounted cast. A dependency-level fix
   may be smaller conceptually if the exact GJK convergence defect can be fixed
   and pinned cleanly. Investigate that while this review runs.
4. Regression coverage: all captured cases; transformed capsule/surface frames;
   tangential and separating travel; a wall/corner in the same surface; the
   real hole remains empty; zero tolerated penetration; budget exhaustion;
   repeated travel with direct geometric nonpenetration checks. Retain the
   unchanged failing reproduction, separate each diagnostic/candidate campaign.
5. Review the eventual implementation against this decision, run the established
   clean sequential gates, and only then use the existing candidate release
   owner. A fresh signed foreground movement campaign is required afterwards.

Please review this plan, not hypothetical implementation. Give GO/NO-GO and
concrete correctness blockers. In particular: does the proposed contact-first
linear cast preserve multi-face collision and rotated-shape behavior, or would
it merely mask a lower-level defect? Recommend the smallest sound integration
using existing owners. Do not advise raising skin/tolerance/budgets, weakening
collision/occupancy checks, hiding uncertainty, inferring collision from GLBs,
adding retry/compatibility paths or duplicating Prolog policy. Do not claim the
feature accepted. Advice is consultative and will be checked against code.
