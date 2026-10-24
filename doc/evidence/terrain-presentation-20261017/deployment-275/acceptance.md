# Terrain presentation release 0.7.275

The movement and appearance correction is deployed at **https://192.168.1.10:30519/**. Sustained walking passed in an existing world and in a world created through the normal GUI. Terrain remained visible, textures were ready, and one authored sky was enabled. **Wild Realm itself has not been updated:** its private appearance requires its owner's signature. Full fresh-creation acceptance remains incomplete because of separate pre-walk GUI lifecycle errors, retained below.

The release is uncommitted. Its exact image is `192.168.1.11:5000/quod:0.7.275@sha256:91246f8aee2a938c3ab34f43d5cb981a686fc95613b0824f3846b679f6ccb073`. Nomad job version 98/index 871075 completed its one-node-at-a-time rollout. All eight nodes passed health, catalogue, predicate-profile, vault, root-application and node-identity checks, including a second check after browser testing. All 33 captured committed prefixes and namespace anchors, the certificate, data volumes, accounts and browser origin were preserved. No ledger, account or volume was deleted.

## Verified behavior

| Actual deployed browser run | Existing Distant Heights | Newly created meadow, re-entry |
| --- | ---: | ---: |
| Held movement | 40 seconds | 40 seconds |
| Horizontal excursion | 14.69 m | 15.00 m |
| Terrain interests | 10 | 12 |
| Content messages / partial batches | 13 / 2 | 14 / 2 |
| Largest content message | 521,057 bytes | 516,336 bytes |
| Unchanged transport guard | 524,288 bytes | 524,288 bytes |
| Maximum physical-frame gap | 1,199 ms | 1,167 ms |
| Rendered frames / hidden terrain frames | 269 / 0 | 265 / 0 |
| Ready attached textured surfaces | 177 / 177 | 152 / 152 |
| Enabled authored skies | 1 | 1 |

Both passing runs used the deployed bundle, no local override, and recorded no page, console, unavailable or socket errors. These observations establish the tested movement behavior; they do not promise a fixed rendering rate or eliminate every loading pause.

[Actual deployed meadow preview](../../../../_build/terrain-presentation-20261017/deployed-meadow-reentry-275-01/after.png)

All twelve clean sequential release gates passed in `clean-presentation-08`: 57 native debug tests, 57 release tests, Clippy, 228 client tests, UI build/lint, 4,084 EUnit tests, 148 Common Tests, xref, Dialyzer and production release, plus the native clean gate. The 1,214-file source manifest is identical to the reviewed clean06 manifest. The only subsequent application-source difference is the separately recorded 274-to-275 version label bump. The full task adds 118 production lines, principally the pure shared wire serializer/measurer and exact batch admission/acknowledgement, with no second runtime owner or compatibility path.

## Review and retained failures

Fable reviewed the bounded-delivery production correction, deployment recipe, owner request and attached-material acceptance correction. No confirmed defect remained in those reviewed corrections. Reports and the parent's independent checks are retained in [review-05](../review-05/fable-review.md), including the [deployment review](../review-05/fable-deployment-review.md), [owner-request review](../review-05/fable-owner-postcondition-09.md) and [harness review](../review-05/fable-harness-03.md).

No failed run was converted to a pass:

- `deployed-walk-275-01` failed a harness assertion that inspected only `scene.materials`. Detached terrain AssetContainers retain their materials on rendered instances. The screenshot showed the texture; an actual Babylon reproduction confirmed the list distinction. Harness03 inspects attached leaf materials and additionally requires enabled terrain occurrences. Fable checked that correction; all movement, transport, sky and error assertions remain.
- `deployed-meadow-275-01` inspected world-list options before the library projection arrived. Its screenshot showed “Loading your worlds”; no creation was submitted. Harness04 uses a non-mutating Playwright trial click to await the enabled Create world control before the unchanged account and unique-name guards.
- `deployed-meadow-275-02` created **Presentation Meadow 275** once, then failed the global error assertion on a pre-walk HTTP503 and unavailable view. Walking, sky and texture measurements were good, but the complete run is not a pass. A separately labeled re-entry into that same created world passed every acceptance assertion; creation was not repeated.
- `deployed-create-diagnostic-275-01` created a separately named diagnostic world once with redacted view-kind and failed-response instrumentation. It confirmed `view_not_authorized_or_ready` on **gui_question**, not the active world view, and `/api/goals/read` returning `503/proof_unavailable`, before walking. It also recorded a socket closed before establishment during page opening. This run remains failed. The signed read predicate and exact error cause were not captured; question retirement is supported by the source but does not prove the HTTP503 cause.

Fable's [creation assessment](../review-05/fable-creation-assessment.md) correctly identified the all-sockets attribution gap and question-retirement possibility. Its ingress-busy hypothesis was disproved by the later response body. [The parent assessment](../review-05/creation-parent-assessment.json) records this correction: normalized proof errors also map to503 in the shared result renderer. No retry, raised cap, ignored assertion or product exception was added. The remaining GUI lifecycle issue is separate from the passing terrain movement checks and remains open.

## Wild Realm

Reload Quod to load the deployed client. The existing Wild Realm retains its original private appearance until its owner applies the reviewed request through the normal console. Follow [the owner instructions](../wild-realm-appearance.md) and use [the complete request](../wild-realm-appearance.pl). It checks the expected original source/state, preserves terrain definitions and ownership, and proves every affected world's complete view within the same atomic transaction. Refusal changes nothing; an uncertain accepted outcome must be resolved rather than resubmitted. No private key is exported.

The same compiled transition committed successfully in the agent-owned account, with terrain definitions unchanged. The final full-view guard passed positive and negative staged proof tests and Fable review. This is evidence for the request, not a claim that Yan's private world has been changed.

## Exact evidence

[Acceptance summary](acceptance.json), [twelve gate receipts](../clean-presentation-08/PASSED.json), [rollout](../../../../_build/terrain-presentation-20261017/deployment-275-rolling/release/PASSED.json), [final fleet check](../../../../_build/terrain-presentation-20261017/deployment-275-rolling/fleet-probe-after-desktop.json), [preserved history](../../../../_build/terrain-presentation-20261017/deployment-275-rolling/history-after.json), [existing-world pass](../../../../_build/terrain-presentation-20261017/deployed-walk-275-02/PASSED.json), [created-world re-entry pass](../../../../_build/terrain-presentation-20261017/deployed-meadow-reentry-275-01/PASSED.json), and [creation diagnostic](../../../../_build/terrain-presentation-20261017/deployed-create-diagnostic-275-01/triage.json).
