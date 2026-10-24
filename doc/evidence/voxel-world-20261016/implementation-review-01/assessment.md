# Checked assessment of the Fable implementation review

**Two defects are confirmed and remain unfixed.** Close them before implementing the live create/list/enter journey. The requested review and planning deliverables are complete; this is not release approval.

Yan explicitly requested Fable. The MCP child used `claude-code:fable` with read-only tools on the exact `clean-gates-04` source snapshot. Its [complete report](fable-review.md) and [assessment of the documentation/evidence supplements](fable-supplement-assessment.md) are retained verbatim. The report was requested again because the session result tool exposed only the later supplement turn. No second review was commissioned.

The parent independently traced the reported paths and ran two isolated characterizations against the compiled, validated production modules. The [check source](reproductions-01/checks.erl.fragment) extends a copy of the existing physics fixture, and the [runner](reproductions-01/run.py) executes only these two functions. The [full log](reproductions-01/run.log) and [receipt](reproductions-01/receipt.json) record an actual child exit of **0** in **8.02 seconds**. This means the defects were reproduced, not that the affected behavior passed correctness acceptance. Existing float-pattern compiler warnings from the copied fixture remain in the log. Production and frozen source hashes remain unchanged.

## 1. Known obstruction is treated as missing terrain

**Confirmed, high priority before entry integration.** The reproduction installs a controlled ball entirely below a plane, with its complete required terrain chunk resident. The real physics owner reports `phase = coverage`, `navigation_ready = false`, and zero steps. Reapplying the identical selection leaves those values unchanged.

The cause is explicit: [the native pre-step check](../../../../native/quod_physics/src/terrain.rs:177) returns an empty coverage demand for known occupancy, ambiguous classification or excessive surface penetration. [The native step](../../../../native/quod_physics/src/lib.rs:530) preserves that classification. [The Erlang owner](../../../../src/quod_physics.erl:544) enters its coverage wait, while `request_terrain([], S)` emits no loading request. Its unchanged-install branch retains the waiting phase.

Qualify the review's “no way to recover”: a suitable committed body or terrain change can make a later changed selection usable. The demonstrated defect is an incorrectly classified wait with no missing chunk that can satisfy it; it is not proof that every possible domain recovery is impossible. The reproduction covers a newly installed controlled body, not a dynamic stack or every ambiguous-contact case.

Required correction and regression:

- Keep missing coverage distinct from occupied, ambiguous or invalid geometry, and report the affected identity and actual reason through the existing physics owner.
- Preserve collision safety and native state. Do not resume by ignoring the embedded body, treating unknown volume as air or adding a retry timer. Use the existing refusal/recovery and governed placement machinery; make any genuinely missing admission capability explicit before extending it.
- Validate the created world's spawn candidate and the final physical placement. The review's suggestion to use a live placement query before initial admission needs care: the current query requires an already installed body identity. It is not automatically a complete initial-admission solution.
- Add a regression through the real owner for complete coverage plus an embedded body, unchanged reselection, an authorized corrective change, and unaffected valid movement. Add resting, stacked and pushed dynamic-body scenarios to determine how the solver's own tolerated penetration interacts with this guard.

## 2. A visual-interest request can invalidate shared physics

**Confirmed, medium priority before entry integration.** Through the existing authenticated signed-view fixture, the reproduction keeps a physical occupant near the origin and sends a camera-interest centre four kilometres away, within the authored chunk-count allowance. It observes **eight sampling calls** followed by a world-invalidation `refresh`. The fixture starts with active, navigation-ready physics.

[The socket parser](../../../../src/quod_client_view.erl:80) accepts canonical integer coordinates. [The physics interest handler](../../../../src/quod_physics.erl:158) checks sequence/current projection and chunk count, but does not first establish that the visual box can coexist with mechanical consumers in an admissible local coordinate frame. [Materialization](../../../../src/quod_runtime.erl:2739) happens before aggregate coordinate admission. A subsequent failure invalidates the world selection and clears the viewer, affecting the shared simulation rather than refusing just that request.

The measured evidence establishes wasted generation and world invalidation; it does not establish a persistent outage duration or a reconnect loop. The fixture uses the supported observer view with a separate controlled occupant, not several simultaneous viewers. The existing one-viewer limit remains unchanged. This is a robustness/availability defect, not evidence that the viewer can read another world's unauthorized terrain.

Required correction and regression:

- Validate proposed visual demand before generation through the existing physics/resource admission path. Refuse inadmissible visual demand for that viewer while retaining physical consumers and the previous valid world state.
- Respect the authorized camera mode and existing tracking allowance. Do not invent a global Erlang distance cap or require every observer to have a controlled body.
- Do not apply the review's suggested current-origin check literally if it would prohibit legitimate rebasing. Check admissibility of the prospective combined window, preserving arbitrary absolute coordinates and normal movement to a new local origin.
- Test distant interest, ordinary near-boundary movement/rebasing, an observer, and a controlled/tracked view. Invalid interest must cause no terrain generation or world invalidation; physical support and unrelated inputs remain usable.

## Other review items

| Item | Parent disposition and follow-up |
| --- | --- |
| Resting/stacked penetration | Plausible trigger for defect 1. The threshold check is present; occurrence under dynamic stacking was not reproduced. Add focused physical scenarios when correcting the gate. |
| Mis-authored terrain mark can crash `view_regions` | The unmatched body-shape pattern and `throw`-only catch are confirmed by inspection. Reachability through a malformed signed projection was not tested. Exercise that boundary and return a specific invalid-binding refusal through the same owner. |
| Lost partial materialization on deadline | The fold discards uninstalled work on error. Repeated work on a later selection is plausible; the report's claim of an automatic infinite loop is not established. Test actual owner wake/retry behavior under a bounded slow-generation case. Preserve original deadlines and policy ownership; do not add a shadow cache or raise the timeout. |
| Large dynamic coverage envelope | The velocity-based conservative envelope is intentional safety accounting. Measure aggregate demand for the intended scene and author adequate Prolog policy; do not shrink safety coverage to fit a fixed constant. |
| Unused halo sampling | Confirmed that this flat-normal kernel extracts the interior 9³ sites while input sampling/hash covers 11³. Optional measured optimization. Any reduction must preserve seam and patch ownership guarantees and account for the current validated native input format; do not silently change it during UI integration. |
| Renewal repeats delivery and temporarily gates commands | Server watch resets delivery-source state; client projection resets `terrainReady`, and command dispatch checks it. This is visible in code and merits a continuous-walking renewal regression. Exact round-trip count and duration were not measured here. Retain verified resources only across equivalent authorized selections and preserve expiry/token fencing. |
| Proof validation and runtime preparation both do work | These are distinct correctness boundaries. Measure changed-edit cost before optimizing; a proof's speculative artifact cannot bypass committed selection or become a second resource owner. Unchanged repeat checks already have separate evidence. |

Fable's non-findings are useful review observations, not new proof of the whole kernel or transport. The earlier clean native/client/Erlang/CT/static/release gates remain evidence for their exact snapshot. Neither those passes nor this review replace the planned authenticated browser walk–dig–return–restart acceptance. Fable did not run tests, and the parent did not rerun the full gates because production code did not change.

The separate [GUI capability experiment](../planning-gui-profile-01/assessment.md) removes the proposed need for another application ontology. It does not change the two terrain defects. The [next milestone plan](../../../../nimbalyst-local/plans/voxel-world-lobby-entry.md) now starts with their correction, then composes worlds into the existing user-owned lobby and extends the shared library/navigation UI.
