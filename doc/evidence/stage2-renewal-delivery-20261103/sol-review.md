# Sol renewal review

Reviewer: GPT-6.1 Sol, high reasoning, agent `/root/renewal_commit_review`. Read-only inspection; no edits, builds, tests, runtime probes, commits or pushes. The report below is retained before parent reconciliation.

Review complete. **No blocking correctness defect found in the renewal correction. Ready for coherent local commit delivery**, including the Erlog correction and Quod’s exact dependency pin/lock update.

- **Low priority — stale comment:** `src/predicates/quod_ask.erl:1491` still claims native admission applies an external-size cap. Current native validation no longer does. Correct the explanation; the completion implementation need not change, and abandoned proposal02 remains excluded.

The checked obligations hold:

1. **Native failure admission preserves semantics.** `erlog_int.erl:258` validates each new reason before prepending it to the already admitted immutable suffix. Invalid reasons still produce the existing single truncation marker; later valid reasons retain their order. Explicit callback policies retain complete-stack validation and marker reservation. Policy installation and checked merging (`erlog_int.erl:233`) prevent switching policies underneath retained reasons and reject malformed incoming stacks.

2. **Removing the default Quod callback is supported by the current prerequisite codec.** `quod_committed_projection:new_est/0:54` now uses native portable validation. Every native accepted constructor is representable by the current wire alphabet; actual failure-stack encoding and decoding (`quod_wire_term.erl:591`) still validate delivery. This conclusion requires the current quota-removal prerequisites; it does not apply to the older codec on Quod HEAD.

3. **The depth-zero shortcut is valid for Quod-managed continuations.** `quod_erlog_db_local_prove:live_transaction_tokens/1:448` skips collection only at depth zero. Scope opening (`quod_proof_scope.erl:32`) clears choicepoints before installing inherited depth. Savepoint commit and rollback (`quod_proof_savepoint.erl:79`) discard inner choicepoints before restoring parent depth. Fresh/committed resets clear both together. Cut removes choicepoints without lowering depth; checkpoint restoration reinstates positive depth. Error handling and reentrant invocation isolation preserve these relationships. Positive-depth collection, inherited base batches and selection invalidation remain unchanged.

4. **Evidence supports the stated bounded result.** I checked the retained 338-test pass, production compilation without `TEST`/`export_all`, configured dependency options and maps assertion. The signed run records 29 lifecycle checks, server/client exits 0/0 and all four EOFs. Three renewals—7.993/8.035/8.003 seconds—completed within the original single 30-second observer, with retained consumer/geometry and zero watched history/rebuild/install/write/sync work. Updates, cycle handling, revocation, stale denial, restoration and reconnect passed. This is one acceptance run, not a latency distribution or full Stage 2/hardware acceptance.

5. **Applied bytes and commit coherence are accounted for.** All six installed correction files match their recorded tested afterimages; attached Erlog matches too. I independently recomputed the proposed selection plus HEAD against **443 tested backend inputs: zero gaps**. These are applied matching sources backed by an isolated tested runtime; no fresh installed-runtime run was performed during this read-only review.

Commit Erlog first, verify its afterimage, then pin both Quod dependency files to that exact revision while retaining the validated prerequisites. A standalone six-line Quod change on HEAD would not recreate the tested runtime. Local commits remain distinct from remote publication; no new push is authorized.

No edits, builds, tests, runtime probes, commits or pushes were performed in this review.

## Parent reconciliation

Accepted the low-priority documentation finding after reading the named source and native validator. Corrected only the four stale comment lines to two current-invariant lines; `comment-correction01.json` records exact before/after hashes and non-comment equivalence. No completion implementation change or abandoned proposal02 application. This is the sole post-test source delta and has no runtime effect. The six functional/test afterimages remain exact. Combined correction including this comment is +18/−14 production lines, net +4.

The parent independently checked native policy installation, admitted suffixes, current wire constructors and checkpoint ownership; no blocking conflict with the review. Dependency commit, both pins and selected committed source hashes will be verified before reporting delivery. Fable did not complete its review; the user explicitly replaced that review with Sol.
