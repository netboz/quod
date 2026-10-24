Complete review-04 report, reproduced in full, followed by the harness assessment.

References are to the frozen tree `_build/terrain-presentation-20261017/review-04/tree/` for production and to `_build/terrain-presentation-20261017/deployment-274/` for recipes. Inspection was read-only: file reads, greps, tree diffs, hash recomputation of the listed recipe files and JSON summaries of the job and history captures. No build, test, edit, memory update or delegation. The stop notifier was not invoked. The parent later confirmed that production and reviewed recipe files remain byte-identical to the review-04 manifests.

## Production verdict

The delta since review-03 is correct and complete for the two confirmed review-03 issues. No new production defect was found.

- **GUI example helper.** `test/quod_gui_examples_tests.erl:187-194` now consumes `terrain_chunks` and acknowledges completion, matching the owner at `src/quod_physics.erl:931-937`. The interest-1 completion check is retained.
- **Lobby sky brightness.** Founding brightness is 1000 at `priv/ontologies/quod_lobby.pl:54`, with the fixture at `test/quod_lobby_tests.erl:1490` aligned, so the lobby panorama renders at full strength under the once-applied semantics at `client/src/render-resources.js:325`.
- **Fog colour.** `client/src/world-scene.js:117-118` scales the tint in linear space and converts back to gamma, matching the dome at every brightness.
- **Shared-credit documentation.** `doc/voxel-world.md:338-340` now states that frames alternate with resources between acknowledgements and that each outstanding delivery retains the credit until its own acknowledgement.

The frozen tree matches the working tree for client, priv, src, test, include and doc. The clean-05 gate tree matches review-04 in every compared code directory, differing only by extra documentation files. The frozen tree reads 0.7.273; the separate label delta is a build precondition, listed below.

## Recipe verdict

The recipes are conservative and preserving: no reset, refounding, volume deletion, identity or provider change; exact predecessor and compare-and-set guards; single submission with recorded intent; unknown responses never retried; retained anchors, prefixes and the TLS certificate compared afterwards. All fourteen listed recipe files match their recorded hashes. The three quod:lobby source edits carry exact-baseline guards and their after texts equal the frozen source. The owner update's before texts equal the pre-fix 0.7.273 source and its after texts equal the frozen source. No confirmed defect that would corrupt state was found. There is one incomplete item the brief itself names, one correctness dependency that the pending acceptance test must assert explicitly, and several risks.

**Verified.**

- `build.py:11-17` admits only a twelve-gate pass with unchanged sources and a review manifest hash equal to the gate manifest, re-hashes every packaged file, excludes native build output and private certificates, checks tag absence before push and the registry digest after, and copies the explorer bundle verbatim with per-file hash checks at lines 21-29 and 68-69. Logs and intents open in exclusive-create mode, so a rerun cannot overwrite evidence.
- `prepare_candidate.py:7-20,33-34` pins candidate job version 95 and modify index 869134, replaces exactly five image references from the pinned 0.7.273 digest to the pinned 0.7.274 digest, asserts counts of eight and zero, and asserts the maintenance diff is only the count change.
- `mutate_once.py:10-18,52-63` fences on review clearance, input hashes, gate pass, verified image, the exact predecessor body, an unchanged main job at version 246 and index 826727, and unchanged ingress, then submits once with `EnforceIndex`. Lost responses are recorded at lines 65-78 and never resubmitted. Observation follows Nomad's blocking index with one absolute deadline at lines 84-106. The candidate job carries group update stanzas with health checks, a healthy deadline of 900 s and a progress deadline of 1200 s, so the release phase produces the deployment the script waits for. Host volumes are per-allocation members of the v11 family and are reused unchanged.
- `history_after.py:14-26` compares all thirty-three retained blocks against the captured prefixes, requires equal genesis anchors and non-regressing applied heights, and pins the ingress certificate fingerprint.
- `fleet_probe.py:114-136` checks job version 97, deployment success, a single pinned image, the volume family, main and ingress job identity, zero restarts, version 0.7.274, eighteen catalogue entries all ready, custody limits, root readiness and committed equals applied, enrollment complete and a stored self-hosting principal on all eight nodes.
- `shared_appearance.py:19-25` executes only after release pass, fleet probe pass and clearance, from the stored compiled goal, and the verify phase at lines 27-29 reads back the palette and the `lobby_options/3` source. The compiled edit in `shared-appearance-prepare-03/result.json` wraps each predicate in an exact `$quod_predicate_source` guard and a post-edit representability check, and preserves clause order.
- `boot_probe.py` renders the production template locally, runs a network-disabled disposable container on a throwaway volume, and `quod_vault_boot_probe.erl` requires vault presence, disabled provider and root readiness.

## Confirmed issues

- **Acceptance request lacks the planned membership removal.** The brief states the Distant Heights fixture holds a direct sky membership fact that must be removed in the same own-account transaction when the derived rule is introduced. `acceptance-owner-update.pl` differs from `wild-realm-owner-update.pl` only in the world label at line 8 and contains no such removal. As frozen it leaves a duplicate membership. The view deduplicates through `priv/ontologies/space_view.pl:5`, so the symptom is a stale fact rather than a visible defect, but the recipe does not yet do what the brief says it must. The newer owner harness addresses this; see the harness assessment.
- **Build precondition not yet met.** `build.py:35` requires the working tree's `rebar.config` and `src/quod.app.src` to already read 0.7.274 while the frozen tree reads 0.7.273. Both currently read 0.7.273. This is the intended separate label delta, so it is a sequencing item, not a defect, but running the script before the bump fails at that line.

## Risks

- **Same-transaction visibility inside the owner update.** `wild-realm-owner-update.pl:6` applies the compiled palette edit, then line 22 calls `world_palette/1` inside a later write block on the same lobby. If a later block within one transaction does not see an earlier block's uncommitted clause change, the old fact still answers, lines 23-30 re-assert the old untextured palette, and the transaction succeeds silently. The acceptance test must assert that the resulting presentation carries texture bindings, not merely that the request committed. Reading the palette directly from the lobby vocabulary in that block would remove the dependency.
- **Ordering between the two appearance steps.** The owner update's edited `world_palette/1` delegates to quod:lobby, so it must run after the shared vocabulary edit has executed and verified. The brief acknowledges this; the scripts do not enforce it.
- **Full stop then full start.** `prepare_candidate.py:12` and `mutate_once.py:7-8` take the candidate from eight to zero and back rather than rolling with the group's existing `MaxParallel` of one. The network is fully down during the window and all eight validators recover together, which is the regime that produced the earlier over-f stall. Data is preserved either way. If a maintenance stop is deliberate, record the reason; otherwise a direct release from version 95 would roll one node at a time.
- **Mixed edit mechanisms in the owner update.** Lines 18-20 add the derived sky member rule by plain `assertz` guarded by `clause/2`, while the other two predicates go through the exact-baseline compiler. The result is semantically equal to `priv/ontologies/lobby_worlds.pl:135-136` but leaves that lobby's `space_member/2` baseline differing in representation from the shipped file for any future source edit.
- **Live genesis dependency.** `world_palette/1` in quod:lobby needs `material_eidolons/2` in the live quod:lobby source. The verify phase of `shared_appearance.py:27-29` exposes a missing fact only after execution.
- **Disposable boot renders with `bootstrap=true`.** `boot_probe.py:11` renders the production template with a bootstrap flag for a network-disabled local container and a throwaway volume. Correct for a boot check; it must never be reused against the cluster.

## Evidence limits

Clean-05 was in progress at review time; EUnit had no result and no `PASSED.json`, `assessment.json`, `review-clearance.json` or `mutation-inputs.json` existed. No recipe has executed; prepare-03 only compiled the shared edit. The owner update has not run against any account. No browser run has exercised the bounded content path or a new textured world with a sky; appearance-preview-01 is a failed timed walk whose screenshot shows readiness only after its deadline. The frozen tree still carries the large uncommitted predecessor delta against HEAD. This review is consultative, not deployment approval.

## Harness assessment

Both harnesses were read after the report above. Neither has run; nothing here is acceptance evidence.

**Owner appearance harness** at `doc/evidence/terrain-presentation-20261017/owner-appearance-acceptance.mjs`. The structure is right: pending operations resolved first and refused if any remain at lines 25-26, the account verified by its two world labels at line 31, the direct Distant Heights sky fact retracted in the same transaction as the derived rule at lines 39-41, unconditional retract so a rerun fails closed, one execute with no retry at lines 50-52, and terrain definitions across the whole lobby compared before and after at lines 53-60. This closes the first confirmed recipe issue. One gap remains, and it is the first risk above:

- **No post-state assertion on what the update was for.** The script asserts only commit, zero pending and unchanged geometry definitions. If the later write block does not see the just-edited `world_palette/1` clause, the request commits while re-asserting the old untextured palette, and this harness passes. Add signed reads after commit and assert them: the Highland Retreat `voxel_presentation` palette contains `texture` bindings, `instance_of(sky_sphere, world_sky(W))` holds for it, `attribute(personal_sky, brightness, 1000)` holds, the derived `space_member` rule is present, and the Distant Heights world view contains exactly one `sky_sphere` mark.

**Walk harness** at `doc/evidence/terrain-presentation-20261017/walk-acceptance.mjs`. The assertions at lines 139-146 cover the original complaint: zero hidden frames, sustained excursion, several interest changes, one enabled sky, ready textured materials. Four points:

- **Default world cannot pass the texture assertion.** Line 8 defaults to Distant Heights, whose palette stays untextured unless the owner update is widened to it. Run against Highland Retreat after the owner update, or through the creation path at lines 65-80, and record which world was used in `PASSED.json`.
- **The freeze symptom is measured but not asserted.** `maximumPoseGapMs` at line 136 is recorded only. The user-facing problem was multi-second frozen poses while streaming, so a bound on that gap belongs in the acceptance; otherwise a run with four-second freezes still passes.
- **Content assertion accepts empty messages.** Line 143 counts every `terrain_chunks` message, including empty fully-retained ones. Require at least one with `encodedBytes` greater than zero to prove the bundle path carried content.
- **Record whether a local bundle was substituted.** When `QUOD_PREVIEW_TREE` is set, lines 21-33 serve the local bundle, but nothing in the observation or `PASSED.json` says so. Write that path into the result so a preview run cannot be mistaken for deployed acceptance. Also consider failing on recorded `console_error` and `unavailable` events, which are collected at lines 37 and 48 but not asserted.

No production or recipe finding changes as a result of the harnesses.
