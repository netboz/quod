Confirmed on the frozen tree-03.

**Scope integrity.** All six manifest hashes match the working tree, the evidence copy is identical, and the scoped six-path diff hashes to exactly tree-03.patch. The delta from tree-02 is only the three things you listed: the doc sentence, the three-line hunk, and the CT restart block. Foreign log, catchup and the unit tests are byte-identical to tree-02.

**The hunk.** `recover_lifecycle/1` has exactly one production line added plus a two-line comment. Its only callers are the two init branches at lines 248 and 250, both reached after the channel, root-runtime and node-actor subscriptions and after the channel is stored in state, and only for a valid configuration. Subscribe-then-reset ordering therefore matches feed. The reset runs for the disabled identity case too, which is correct: any peer-opened directory stream belongs to the old incarnation regardless.

**The CT.** It does what I asked. It captures the applicant's root generation and the old link pid, restarts only the custodian's directory control through the supervisor, waits for a strictly newer root-authored generation observed from the applicant's directory state, asserts a different link pid, one subscriber on the custodian, one control link on the applicant, and then a further natural renewal over the reinstalled stream. Remote-05 reproduced the defect with the expected generation-not-received failure and remote-06 passes with the fix.

**One minor note, not a change request.** If a natural renewal lands in the sub-second gap between capturing the baseline and terminating the child, the first post-restart wait could be satisfied by the old stream and the link assertion would then fail rather than pass falsely. So the risk is a rare flake, never a false green. If it ever shows, wait for the new link pid before the generation wait.

Verdict unchanged: approve tree-03 for commit once gates-03 completes green. The earlier retraction stands archived.
