# Terrain review fixes: checked assessment

The two original defects and the three related defects discovered during validation are corrected in the frozen `clean-fixes-04` scope. [Claude Fable's complete final report](fable-review-04.md) finds no remaining confirmed defect within that scope. [All twelve clean sequential gates passed](../clean-fixes-04/PASSED.json), and the runner completed with actual exit 0. No required check for this repair scope remains pending.

## Scope and authority

Yan authorized the fixes, refactoring and stale-code removal without backward compatibility, and requested Claude validation through MCP. This campaign changes existing physics and terrain owners; it does not implement lobby world creation/entry, install source into live ontologies, deploy, bump a version or commit. Earlier uncommitted terrain implementation and user-owned files remain preserved.

[Final scope](final-scope.json), [source manifest](../clean-fixes-04/source-manifest.json), [review document hashes](review-documents-04.json), [exact patch](fixes-04.patch), and [production line delta](production-line-delta-04.json) identify the reviewed work against `clean-gates-04`. The [final verification](final-verification.json) confirms all 1198 source entries and four review documents match both the frozen and live trees after the gates completed.

## Corrected behavior

1. Missing chunks carry concrete coverage requirements. Known obstruction and ambiguous geometry carry explicit affected-body outcomes. The owner preserves its native incarnation and motion, refuses unsafe integration, performs no work on unchanged reselection, and resumes after a governed correction. The old bug was a misclassified unsatisfiable coverage wait; even the old implementation could sometimes recover after a domain edit, so it was not universally unrecoverable.
2. Viewer interest is admitted against the existing joint coordinate allowance before generation. An incoherent request is refused through the existing per-view resource path without invalidating shared physics. A valid observer rebase and huge absolute coordinates remain supported. This fixes an availability defect; it does not change terrain viewing authorization.
3. Rebuilding a chunk after digging elsewhere no longer re-admits its unchanged solver contacts. Exact oriented new faces are checked against retained bodies; new bodies and authored pose changes check the complete current surface. The last integrated baseline survives repeated unintegrated edits. New rock intersecting an existing contact is still refused even when the body's centre is in air.
4. A pending checkpoint restoration retains its original insertion and mechanical demand across identical selection, defaults/control-only selection and an `advance` wake. An explicit pending result replaces the artificial empty request.
5. A coordinate refusal followed by the original unchanged pending-restoration selection remains in coverage, with navigation unavailable. Installation phase is derived from pending work before control installation; it cannot advertise readiness while the checkpoint still waits.

The [cleanup audit](cleanup-audit-04.json) traces the replacements and their callers. The coordinate-only phase, duplicate resume branches, collider-wide terrain admission marker, old step-coverage helper and fake empty restore demand are removed. No compatibility path, second owner, queue, domain engine or retry timer was introduced. Shared coordinate computation is extracted once. The net increase is **97 production lines** across five existing modules, excluding tests: explicit outcomes and view admission plus exact changed-face comparison and its bounded pending baseline account for the growth. Runtime and client-view production modules are unchanged in this campaign.

## Independent verification of Fable's advice

Both follow-up findings from report 02 were reproduced before changing their implementation. The parent additionally reproduced the readiness defect after the third freeze. [All failed focused runs and their disposition](failure-triage-index.json) are retained; no failure was silently overwritten or treated as passing evidence.

The proposed blanket exemption of previously contacting collider pairs was not adopted. It can exempt newly added rock in an existing pair. The implemented comparison retains only exact unchanged faces, with a negative test for newly intersecting rock and another for repeated blocked replacements. No tolerance was raised.

The native impact fixture measures 8.2612 mm maximum contact penetration at tick 17 and 0.0692 mm after settling, and passes same-chunk edits at ticks 17 and 400. Its final bodies settle side by side; final rotated-body AABBs remain within Rapier's existing 5 mm tolerance. A separate owner fixture proves an actual loaded stack through published contact identities and vertical ordering before and after a real signed `voxel_edit`. It also verifies unchanged native incarnation, resumed stepping, a changed chunk digest and no work on unchanged reconciliation. These claims have distinct evidence; the native fixture alone does not prove permanent stacked support.

The phase correction was checked against all installation outcomes, including an intervening coordinate refusal. The two pending-restoration variants retain the original 18 m insertion even if the source checkpoint changes or disappears. Trace-backed repeat checks synchronize on delivered traces and actual owner processing, not sleeps. They cover sampling, native installation, history reads and persistence writes/syncs as applicable to the exercised path.

## Remaining risks and integration acceptance

These are bounded limitations and review questions, not additional reproduced failures in this campaign:

- Digging directly at a deeply penetrating impact contact may create changed faces that still intersect the body beyond the solver tolerance. The current correction proves an edit elsewhere in the same chunk. Add a deterministic contact-centred dig case before claiming every pure dig is harmless. Fable's optional maximum-penetration comparison is not accepted as a proof: comparing one deepest distance does not by itself prove that new solid intersects no previously clear body region, and the report did not derive monotonicity of the quantized MC33 surface.
- A viewer window valid when requested can become incompatible after physical consumers move near the common coordinate limit. Pending teleport targets are not part of that prospective view check. Existing motion and frame checks remain safe, but this campaign does not prove uninterrupted availability under those changing demands. Exercise the boundary through real owner and signed-view paths during world-entry integration.
- An attached client does not receive a specific blocked reason from the existing status subscriber. The physics owner and runtime do receive it. World-entry presentation must expose the actual loading/blocked state without inventing an automatic retry loop or treating missing coverage as empty terrain.
- Removing the last terrain body leaves an old internal mechanical-demand value. A normal replacement selection updates the frame/structure, stale interest fails projection checks, and a later terrain-bearing publication recomputes mechanical ranges. The report does not establish a valid client sequence that makes this stale value an availability defect. Keep removal/re-add coverage in integration acceptance; do not mistake an internal stale value for a proven public failure.
- Returning from blocked to pending coverage retains the runtime's previous unavailable reason until a later notice. The owner correctly reports coverage and navigation unavailable, and runtime reconciliation treats both statuses as unavailable. More precise status presentation can be added when that distinction has a consumer.
- Changed-surface construction uses a nonempty subset of already valid triangle indices and the same constructor as the original collider. The fallible signature is conservative; an actual native installation error follows existing fatal retirement. This is not a separate recoverable partial-install path.

## Validation evidence

The authoritative final results are the [clean-fixes-04 receipts](../clean-fixes-04/results.json) and [completion record](../clean-fixes-04/PASSED.json). Positive test completion summaries are required as well as actual child exits; source hashes were unchanged at every gate boundary. Fable's final report describes the receipts available when it read them; the parent subsequently verified completion of the remaining gates.

- Native: 57 tests passed in both debug and release builds; clippy with warnings denied passed.
- Client: 206 tests passed; UI build and lint passed, including preservation of public assets.
- Erlang: 4,057 EUnit tests and 148 Common Test cases passed, with positive completion summaries and exit 0.
- Cross-reference analysis, Dialyzer and production release assembly passed with exit 0.

The earlier full `clean-fixes-02` run passed but predates the three follow-up corrections. `clean-fixes-01` stopped on a sandbox-denied localhost bind. `clean-fixes-03` was deliberately stopped after the readiness defect was reproduced: EUnit's SIGTERM handler exited zero without a completion summary, which is not a pass; the runner's subsequent CT child was stopped and recorded exit -9. Both stop requests, the actual exits, full logs, triage and a check for remaining test processes are retained. The final runner additionally rejects an absent completion summary or an explicit stop request.

The review was consultative source inspection. Fable ran no tests or builds. Its session metadata lists a Claude-local memory-file edit from an earlier review turn; no implementation edit by the child is attributed to it. The parent owns the code changes, reproductions, gates and checked conclusions.

The historical report 03 was reproduced after report 04 had been saved, because MCP exposes only the latest full turn. The session's latest response can therefore describe the superseded snapshot. The authoritative final-source verdict is the complete archived report 04 linked above; report 03 and its retrieval receipt remain historical evidence.
