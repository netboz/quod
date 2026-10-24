Reading the deployment brief, manifest and delta.

No further items are needed; all evidence is in hand. Complete report follows.

References are to `_build/terrain-presentation-20261017/deployment-275-rolling/` and `doc/evidence/terrain-presentation-20261017/`. Inspection was read-only: patch and file reads, hash recomputation of the eighteen manifest files and of the gate manifests, and JSON summaries of the captured jobs. No command, test, build, edit, memory update, delegation or deployment. All eighteen manifest entries match on disk.

## Verdict

The 275 recipe is the previously reviewed rolling recipe with only scope, version, index and predecessor changes, plus a read-only preflight whose captured state is internally consistent with every guard the later scripts enforce. The corrected mutation script retains the literal file selection and the `input_name` loop variable, so the earlier shadowing defect does not recur. The walk harness additions assert the actual property that failed in 274. I found no confirmed defect. Gates, image, generated desired job, Nomad plan, clearance files and browser results do not yet exist and remain the parent's execution obligations.

**Confirmed, by reading.**

- **Preflight is read-only and self-consistent.** `preflight.py:9-10` writes only exclusive-create local files and issues only GET requests. It asserts candidate version 97 and index 870647, main 246 and 826727, ingress 1 and 846370, eight running allocations with zero restarts, eight host volumes of the v11 family, and a single quod image equal to the pinned 273 digest at lines 12-22, then captures all thirty-three namespace blocks and the certificate. The saved captures agree: `candidate-before.json` is version 97, index 870647, counts eight and zero, update stanza `MaxParallel` 1 with health checks, volume source v11, and every quod task on the 273 digest; `history-before.json` holds thirty-three blocks with `read_only` true.
- **Guard coherence across scripts.** `prepare_candidate.py:8-10` requires that same version 97, index 870647 and old 273 digest and produces exactly five image-only changes against a pinned 275 digest. `mutate_once.py:7-16` keeps `candidate-release.json` and `candidate-before.json` as literal paths, requires the clean08 `PASSED.json`, the verified image, clearance and input hashes, and expects precisely one destructive update; the 1200 s indexed observation and no-resubmission handling are unchanged. `fleet_probe.py:13,114,120,124` expects version 98, the unchanged ingress identity and node version 0.7.275. `history_after.py` is byte-identical to the reviewed version and compares the new capture.
- **Source and label separation.** `build.py:8-17` packages only the clean08 tree, requires twelve zero-exit gate results with unchanged sources, and ties the independently assessed `review-05/assessment.json` to the gate manifest hash. That hash equals the clean06 manifest hash, so clean08 gates the exact reviewed source. Lines 31-37 require the frozen tree to read 0.7.274 exactly once per file and the working tree to carry the 0.7.275 label delta; the working tree currently reads 0.7.274, so the label bump remains a deliberate precondition after gates pass, as the brief states.
- **Preservation and non-resubmission.** No script deletes volumes, ledgers, identities or accounts; the rollout is the group's own one-at-a-time destructive update; an uncertain submission is recorded and never repeated; evidence files are exclusive-create.
- **Harness.** `walk-acceptance-02.mjs:14` refuses an existing campaign directory. Line 40 records the real received frame size, completion flag and acknowledgement form. Lines 135-136 require every content frame at or under 512 KiB, which is exactly the guard that closed the 274 socket, and at least one partial batch, which proves the window crossed a boundary rather than fitting by chance. The forty-second walk, error, hidden-frame, excursion, interest, pose-gap, sky, texture and deployed-bundle assertions are unchanged; the diff against the reviewed harness is only the patch's four hunks.

## Remaining evidence limits

- No clean08 pass, no `PASSED.json`, no `assessment.json` linkage to a passed gate, no image 275, no `verified-image.json`, no generated release body, no dry plan, no clearance or input manifests. Every script above fails closed without them.
- The 1200 s observation deadline is unchanged; a serial eight-node roll may outrun it, and the parent's stated handling, read-only inspection of the original submission and never resubmitting, stands.
- Sessions open across node 0's restart still need a reload.
- The partial-batch assertion presumes the acceptance world's first window exceeds one frame; a smaller world would fail that assertion honestly rather than pass falsely.
- I did not re-verify the thirty-three prefix files individually beyond their presence and count, and I did not re-review unchanged production or the owner helper.
- This review is consultative, not deployment approval.
