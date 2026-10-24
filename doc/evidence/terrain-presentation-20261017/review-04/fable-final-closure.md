Reading the final correction patch and re-verifying the updated manifest hashes.

Closure for the final recipe correction. Read-only: patch read, hash recomputation of the updated manifest, and a check of the corrected lines in place.

**The confirmed defect is closed.** In `_build/terrain-presentation-20261017/deployment-274-rolling/mutate_once.py` the mutable selector is gone. Line 7 keeps only `expected_updates`, the manifest loop at lines 10-11 binds `input_name`, and lines 14-15 load `candidate-release.json` and `candidate-before.json` as literal paths. The only remaining `name` is the local parameter of `save` at line 17, which is scoped to that function. The installed file matches the patch and its recorded hash. Downstream guards are unaffected: the plan must still show exactly one destructive update, the predecessor index is still enforced, and nothing is resubmitted.

**Walk excursion tightening is correct.** `doc/evidence/terrain-presentation-20261017/walk-acceptance.mjs:121` now measures horizontal distance only, so a fall or a spawn drop cannot satisfy the eight-metre requirement at line 133. The installed file matches the patch and its hash. All twenty-four entries in the updated `rolling-scripts.json` match on disk.

**No new concern in these deltas.**

**Unchanged limitations.** The 1200 s observation deadline remains shorter than a serial eight-node roll can take; the parent's stated handling, read-only inspection of the original submission and never resubmitting, is the right response if it expires. Sessions open across node 0's restart still need a reload. Nothing has executed: no image is built, `review-clearance.json` and `mutation-inputs.json` do not exist, the version label bump is not applied, `shared-appearance-verify-03` does not exist, and clean05 has no `PASSED.json`. This is consultative, not deployment or acceptance approval.
