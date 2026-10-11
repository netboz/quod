# Candidate 0.7.262 deployment

Implementation commit: `fd2623ee93662d873315e78f2756e7d96c268fd4`. Separate label:
`f237b7e9a33e05358b186c6b07975a610294a6fa`. All eleven clean release gates passed on the
exact committed inputs, including 3884 EUnit tests and 146 Common Test cases.
Fable approved the main implementation; Opus 5.5 approved its narrow follow-up.
Their inspection scopes and independent disposition are retained separately.

The committed image passed the isolated network-disabled boot check, preserved
all 176 tested browser asset hashes, and was published with the verified digest:
`192.168.1.11:5000/quod:0.7.262@sha256:279a231f4344a2213da56661c22d72b9f2864afde7fe57363716757862b95386`.

The existing deployment workflow submitted one indexed maintenance transition
and one indexed release transition. The complete job comparison permits only
node count 8 to 0 during maintenance and five pinned image substitutions for
release. Volumes, constraints, services, templates, health checks and stable
browser ingress were preserved. Automatic rollback is disabled; the exact prior
job is retained. No uncertain mutation was resubmitted.

The candidate is job version 69, JobModifyIndex
847378, deployment `bcd1da01-578c-b838-067a-2e6394978158`. All eight
allocations are healthy with zero restarts, identical retained node principals,
the same root anchor and 18 ready system ontologies per node. The separate main
job remains version 246 / JobModifyIndex 826727. No server write remains active,
and no additional release or refound is queued from this scope.

The existing personal actor and world anchors are unchanged. Their recorded
history tips (human 358, world 184) and older prefixes (350, 176) are byte-for-byte
unchanged. The world has advanced to height 186 during recovery; this is not a
history rewrite. Its physics owner is active with navigation ready and structure
1. The TLS certificate and browser origin are unchanged. No refound was needed.

The coordinated longer desktop renewal recording is still pending. These
checks do not establish visible movement continuity and do not close the tracker
item. No browser was opened and no desktop input was sent for this deployment.

The unchanged boot probe source, exact compiled fixture and original compiler
receipt are retained in vault-boot-probe.tar.gz. This avoids losing the compiled
fixture to the repository-wide .beam ignore rule.
