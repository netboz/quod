# World library 0.7.273: deployed acceptance

The first usable world-library milestone is deployed at
[Quod](https://192.168.1.10:30519/). Create an account on this fresh candidate,
then open **My worlds → Set up world tools → Create world**. The existing GUI
provides landscape, seed, ground detail, world size, biome size, height and cave
controls. A blank name draws and saves a name from the naming ontology. Worlds
remain owned instances in the user's lobby ontology, with their own physical
authorities and pilots.

The exact 0.7.273 image is pinned in [the summary](summary.json). Its application
source is frozen07 plus the separate version-only label delta; all 1,212 frozen
entries still match, and live source differs only in those two version labels.
Source changes remain uncommitted. No compatibility path was retained.

All twelve [release gates](../clean-integration-07/PASSED.json) passed: native
debug and release 57 each, client 217, EUnit 4,080, Common Test 148, clippy, UI
build/lint, xref, Dialyzer and production assembly. Fable's completed
[application review](../review-06/fable-review.md) found no remaining confirmed
defect; [frozen07's assessment](../review-07/assessment.md) verifies identical
production and the sole test-fixture correction.

The [deployed browser journey](browser.json) used a fresh account and normal
signed GUI actions. It created **Distant Heights** with the generated name and
**Highland Retreat** with a typed name, using meadow/1 m and highlands/0.5 m
settings. It walked in both, returned to the lobby, reopened the same saved
world and walked again. Observed horizontal travel was 1.458 m, 1.168 m and
1.418 m respectively. The run ended with zero pending operations and zero page
errors. [Full observation](browser-observation.json), [true child exit](desktop-exit.json),
[meadow image](meadow.png) and [highlands image](highlands.png) are retained.

The final [fleet probe](fleet.json) passed on all eight nodes: version 0.7.273,
zero restarts, the same new root, all 18 system ontologies ready and exact module
profiles installed. Main job version 246/index 826727 and ingress version
1/index 846370 remain unchanged. After browser and fleet acceptance, the exact
16 retired v9/v10 candidate volumes were [deleted](retired-volumes.json).
Candidate accounts and ledgers were reset under the user's explicit overnight
authority. The temporary local preview was shut down intentionally.

Failed campaigns remain intact. The first deployment omitted the GUI native
module from its immutable founding recipe; the [corrected recipe and independent
assessment](../deployment-02-independent-assessment.md) add and verify it through
ordinary founding. A later browser timeout was an input synchronization defect
in the harness, independently isolated with captured zero/nonzero drive goals;
[its triage](../deployed-reentry-triage.md) records the correction without any
application change or weakened movement assertion. The additional Fable recipe
consultation hit the provider session limit; [its receipt](../deployment-02-fable-receipt.json)
records that no such review completed. This does not replace or extend the
completed application review.

The feature's [production delta](production-delta.json) is +995/-338, net +657
lines across 40 files. Growth implements the library's domain policy, shared
space selection and Prolog-owned material admission; superseded lobby-only
setup paths were removed. Tests and failed evidence were preserved.

This is headless desktop acceptance, not physical VR validation or a terrain
performance benchmark. Materials remain simple. Texture blending, broader
biome authoring, further book-name imports, cubic packs, public world discovery
and moving the flying lobby remain separate work. The broader terrain plan and
its exploratory acceptance matrix remain in progress.
