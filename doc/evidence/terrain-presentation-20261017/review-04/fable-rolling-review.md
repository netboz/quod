Reading the recipe follow-up brief, the rolling scripts manifest and the patch.

No further items needed. Final report for the rolling recipe follow-up.

References are to `_build/terrain-presentation-20261017/deployment-274-rolling/` and the two harnesses under `doc/evidence/terrain-presentation-20261017/`. Inspection was read-only: file reads, hash recomputation of the twenty-four listed files and JSON summaries of the plan probe and ingress capture. No build, test, edit, memory update or delegation. Production, frozen04 and clean05 were not re-reviewed.

## Verdict

The deltas do what the follow-up says. The rollout is now the job's own one-at-a-time destructive update, the owner goal no longer depends on same-transaction visibility, the shared execution checks its live prerequisite and verifies all three edited predicates against the exact after-source before emitting `verified`, and both harnesses carry the post-state and deployed-walk assertions I asked for. All twenty-four files match their recorded hashes. One confirmed defect remains in the mutation script; it fails closed in most cases but must be fixed before clearance. Nothing has executed, no image is built, and clean05 is still running.

**Verified.**

- `prepare_candidate.py` writes only the release and rollback bodies and asserts the release diff is exactly the five image references.
- `mutate_once.py:7` expects precisely one `DestructiveUpdate` on `quod-node`, and the read-only plan in `rolling-plan-probe.json` shows exactly that with seven ignored, no cloud update, no warnings and no failed placement. The compare-and-set, unchanged main job and ingress checks, exclusive-create evidence files and no-resubmission handling are unchanged.
- `fleet_probe.py:114` now requires job version 96. The other fleet assertions are unchanged.
- `shared_appearance.py:25` proves `material_eidolons/2` in the live quod:lobby before any write. Lines 27-35 build, for each edited predicate, parse of the after-source into clauses, canonical reprint, and equality with the live `$quod_predicate_source`, which matches the primitive contracts at `src/predicates/quod_common_primitives.erl:31,49`. `verified:true` is emitted only after every check holds.
- `wild-realm-owner-update.pl:22-23` and `acceptance-owner-update.pl:22-23` read the palette from the pinned lobby vocabulary. The exact old-default guards, the single transaction and the brightness guard are unchanged.
- The browser endpoint is one node: the ingress capture routes TLS passthrough to the `candidate-quod-node-0` client service, and `src/quod_client_view.erl:456-458` attaches only a locally registered physics owner. The changed terrain wire is therefore local to node 0 and its colocated owner, as the follow-up states. Sessions open across node 0's restart need a reload.
- Owner harness: line 13 refuses to run without `shared-appearance-verify-03/result.json` reporting `verified`, enforcing shared-before-owner order. Lines 46-55 assert in one signed read the textured material 1 of Highland Retreat, its sky instance, personal sky brightness 1000, the derived membership rule via `clause/2`, and exactly one `sky_sphere` mark in the Distant Heights view. The direct fixture member is retracted in the same transaction at lines 58-60, definitions must be identical and pending operations zero.
- Walk harness: explicit URL and world at lines 10-11, refusal of any local bundle at line 12, `previewTree: null` recorded, non-empty content at line 135, pose gap under two seconds at line 136, console, socket and unavailable events rejected at line 130, and URL, world and creation recorded in `PASSED.json` at lines 144-145. The earlier assertions remain.

## Confirmed issue

- **Variable shadowing selects the wrong job body.** `mutate_once.py:7` sets `name` to `candidate-release.json`, but the loop at line 10 rebinds `name` to each key of `mutation-inputs.json`, and line 14 then loads `desired` from whichever key came last. The original script assigned `name` after that loop. Depending on the manifest's key order this raises on a missing `ID`, plans a no-op that the `DestructiveUpdate` guard rejects, or by coincidence works. Rename the loop variable or move the assignment below the loop, and re-record the script hash in `rolling-scripts.json` and `mutation-inputs.json`.

## Risks

- **Observation deadline versus a serial eight-node roll.** `mutate_once.py` keeps a single 1200 s observation deadline while the group's own progress deadline is 1200 s per allocation progress and each node must restart, rejoin and pass its checks before the next begins. If the roll outruns the deadline the script raises, the deployment continues, and the exclusive `release` directory prevents a second run. A separate read-only observation re-entry that only watches the existing deployment id would avoid an unrecorded success. The fleet probe still requires deployment success, so nothing is silently accepted.
- **Mid-roll browser sessions.** A session that stays open while node 0 restarts keeps old client code against the new wire and stalls until reload. Expected and acknowledged; worth a note in the rollout record.
- **Derived rule added by guarded `assertz`.** Representation is now stated to equal the compiler's output and the owner harness checks the clause semantically. Accepted; the earlier concern is answered.
- **Distant Heights texturing.** The parent's evidence that the fixture already textured it removes the default-world concern; explicit world selection makes it moot.

## Evidence limits

No recipe or harness has run; prepare-03 compiled the shared edit only, and `shared-appearance-verify-03` does not exist yet. The image is not built, `review-clearance.json` and `mutation-inputs.json` do not exist, the version label bump has not been applied, and clean05 has no `PASSED.json`. This review is consultative, not deployment or acceptance approval.
