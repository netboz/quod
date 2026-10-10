# Mixed-scene review disposition

Claude/Fable reviewed the frozen 23-file mixed-scene packet in `mixed-view-review-01`: exit 0, no frozen-input changes, model `claude-fable-5-1`. The report found the pose writer, parent conversion and exact body/revision binding coherent. It identified shared-policy and model-construction gaps. These findings were checked against the actual sources before correction.

1. Reused the exact authored `rendering_vocabulary(Namespace, Anchor)` and its existing `well_formed_scene/1` proof. Removed the weaker duplicate scene validator from physics. Scene size, geometry, material, ID/label limits and parent ordering remain rendering-owned Prolog policy.
2. Removed the redundant physics-view MaxPoses check. Native installation/sample policy already enforces that budget. The shared rendering scene budget independently counts decorative occurrences.
3. Extended the existing modelling transform conversion to preserve both body-pose forms. Added a recipe construction test using the shared rendering schema.
4. Removed the duplicate body-pose schema comment. Kept two explicit nonrecursive attachment-pose clauses for readability; they prevent nested relative terms.

The signed view fixture now founds and reads the existing rendering vocabulary as a separate real ontology, with an exact reference. Reused/exported the existing test ontology lifecycle helpers instead of copying setup/teardown. A new signed test checks malformed hierarchy, duplicate occurrence IDs, missing anchored body subjects, stale body revisions, fractional transforms, repeated occurrences of one body, and a real rendering-owner scene budget edit. Client tests additionally cover moving physical parents and replacement parents while retaining the child's engine object and world pose.

`mixed-view-server-01` failed on the prior mark-count budget; `-02` passed 16 tests before the review corrections. `mixed-view-owner-regression-01` passed 150 tests before those corrections. `mixed-view-schema-01` failed with undef because the reused test lifecycle helpers were private; they were exported with actual callers. `-02` passed 16 tests; `-03` passed 18 tests with additional refusal and recipe coverage. `mixed-view-client-full-02` passed all 14 client test files. Every labelled attempt and source-hash receipt is retained.

The review also cited existing native sampling and modelling sources outside its 23-file frozen inventory. Those claims were independently checked; do not treat those files as frozen inputs to that review. The follow-up packet must include them explicitly.

This is still a partial stage. Adding the rendering scope makes the already-known missing generic view-dependency retention directly relevant: the old socket only follows acting-agent and simulation scopes. The next-stage plan addresses that owner, including failed/disabled selections. No deployment or ordinary-view/lobby acceptance is claimed while that gap remains. Remote collider installation, physical admission/withdrawal and actual signed current-lobby acceptance remain outstanding.

The corrected broad regression `mixed-view-owner-regression-02` ran 152 tests with one failure: removing the redundant pose-count check also removed the required resource-policy presence check. The signed view incorrectly succeeded after allowances were withdrawn while runtime reconciliation was deliberately suspended. Restored `physics_required_allowances/5` without duplicating the pose-count policy. Failure log and fixture `/tmp/quod_hosted_5E1C552CEEE53F8C` are retained; the correction is tested separately as `mixed-view-owner-regression-03`.

`mixed-view-owner-regression-03` passed all 152 tests (exit 0; tracked inputs unchanged), including the restored refusal when resource allowances are missing.
