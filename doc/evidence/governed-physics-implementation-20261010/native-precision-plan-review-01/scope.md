# Plan gate: native precision after a reproduced triangle-edge freeze

Yan authorized continued implementation, review, commits/deployment/refound while
asleep, explicitly without backward compatibility. Fable exhausted model credits;
Yan authorized latest Opus fallback. Review this concrete plan, using the supplied
code and failed/passing probes. Give GO/NO-GO with necessary corrections. This is
not implementation or release approval. No tools, edits or deployment.

Your preceding implementation review correctly stopped the convergence hunk.
It is reverted. Bounded traces cover GJK exits/refinement outcomes: no contact-None
in the captured cases, 8,736 reciprocal steps or 23,920 travel cases (two frames,
five velocity profiles including horizontal free travel at 2/8 m/s). Whole meshes
pass. An independent analytic capsule-to-triangle edge oracle nonetheless finds
0.069428 rad normal error in binary32. We then isolated that exact supported
triangle: ordinary 2 m/s grazing travel returns Occupied, i.e. another freeze.
This is a concrete supported-geometry failure, not a speculative precision upgrade.

Binary64 probe03, using the same minimal GJK stagnation/iteration correction,
fixes the edge at 2/4/8 m/s and passes 33/34 tests. The remaining original strict
query-count test fails (10 vs <10) because the current 16*machine-epsilon slide
bias is smaller than the contact-normal solver error. Probe04 logs repeated
contacts whose normals differ by about 1e-10; machine epsilon is 2e-16.
Probe05 uses the existing GJK relative tolerance sqrt(gjk::eps_tol()) for the
existing separation bias instead. All 34 tests pass without changing any
budget, collision assertion or original query-count bound. This bias is about
4.7e-8 of remaining travel, tied to the same solver's numerical precision.

Proposed clean replacement, not a second engine:
1. Use Rapier3d-f64 0.36.0 / Parry3d-f64 0.31.1 for the existing World and all
   native geometry/queries/dynamics. The NIF inputs/outputs and Erlang/JS numbers
   already use binary64. There is no wire/schema/body-identity change, new native
   owner or duplicated query world. Remove all binary32 downcasts, redundant
   representation checks, old dependencies and obsolete docs. Do not keep two
   precisions or an old/new switch.
2. Keep the small verified Parry patch for time-zero stagnation and iteration
   exhaustion, scoped to shape casts. No convergence hunk or contact precheck.
   Move the vendor provenance to the verified published f64 package, and remove
   the old f32 package entirely. Retain upstream license and minimal diff.
3. Use the library's relative geometric tolerance for the existing slide bias;
   do not raise narrow-phase or iteration allowances. Remove the obsolete local
   16*binary32-epsilon assumption. Confirm drift, corners, rotation, walls, holes,
   occupied endpoints and exact N/N-1 budgets in both native build profiles.
4. Update Prolog's single native scalar encoding envelope to finite binary64.
   It remains an encoding constraint, not a resource budget. Current millimetre
   fields allow Max*1000, whereas Erlang X/1000 can overflow converting a huge
   integer before division. Use one shared interface conversion in the current
   Erlang physics owner (integer quotient plus scaled remainder) for milli/micro
   fields, keeping finite bounds in Prolog. Remove superseded scalar conversions;
   no private policy in Erlang and no arbitrary ceiling. Density/motor scalars
   stay direct finite binary64. Test actual maximum/overflow encoding separately
   from Prolog coordinate/resource limits and refuse the resource actually exceeded.
5. Extend the final native suite with the isolated-edge failure, the 23,920-case
   matrix, an independent exact triangle-face/edge normal oracle and bounded
   removable exit/refinement tracing. Re-measure binary64 normal errors before
   choosing a regression bound. Preserve every failed probe; don't relax tests.
   Audit public reachability: dynamic bodies do enable CCD, but Rapier0.36 CCD
   uses sweep_toi and nonlinear casts; those do not call directional_distance.
   Its other public consumers are QueryPipeline::cast_shape and the unused
   character controller; Quod reaches linear casts through its Space owner.
6. Measure native step/sample/query cost on the same retained-body fixtures in
   isolated release builds. Counts/budgets remain Prolog policy; report actual
   time/memory cost and do not hide a capacity problem by increasing policy.
   Run clean sequential full release gates and an implementation review.
7. Cold-deploy the single compatible candidate cohort through the existing
   writer/authority. The exact current personal-world anchors/history remain;
   no refound is needed merely for internal numeric precision. Immutable founding
   manifests are not rewritten. Existing authored policy may constrain values
   below the new encoding envelope; its normal working geometry is unchanged.
   Record restored current verified state/new run, then normal signed desktop
   console/roof/opening contact and the matched sustained movement run. Close
   the ticket only on its own acceptance; XR and durable door consequences remain
   separate tickets.

Please assess whether this is the smallest sound response to the reproduced
edge failure, the numerical bias rationale, representation/conversion ownership,
resource-cost obligations and any genuinely missing deployment contract. If you
prefer an f32 refinement correction, identify the existing owner and concrete
mechanism; avoid a guessed tolerance increase or another contact query in Quod.

Production is still binary32 and candidate262 is still running. All full gate03
checks passed but the reviewed candidate is explicitly NOT FOR RELEASE. No
production precision change, commit, deployment, refound or new browser occurred.
