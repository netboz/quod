**Verdict: not yet a go. One blocker, three preflight corrections, one sequencing recommendation. The ingress half of the plan is sound and matches the repo template; the candidate half is the part the packet does not let me check.**

**Verified against the packet.**

- Both frozen ingress jobs are faithful renderings of `tree/deploy/quod-client.nomad`: same constraint, args, resources, check, static port, and the template differs only in the selected tag.
- Route semantics are right for this origin. The IP-literal origin sends no SNI, so `HostSNI(*)` is the correct rule. Consul-template returns passing instances only, so "exactly one healthy tagged backend else no route" holds, and the maintenance tag selects nothing.
- Discovery shows the tag `candidate-quod-node-0` uniquely on conrad:30519. The ingress service name does not collide with the fleet's `service "quod"` seed query. Rate policy capture is empty, matching the README caveat.
- Anchors and heights in the plan agree with the 259 baseline and owner-active captures. Create uses check-index 0 correctly.

**Blocker.**

- **The two candidate mutations are not in the packet.** The reserve and active ingress bodies are frozen, but the version-63 job spec, the Count-0 body, and the Count-8-plus-260-digest body are not. The plan's claims (five image occurrences, tags preserved, only Count changed, 259 image available for rollback) rest on that spec. The repo `tree/deploy/quod.nomad` cannot be its source: it has no per-index tag and hard-codes job name `quod`, while the live candidate carries `candidate-quod-node-N` tags and prefixed service names. Freeze version 63 and both diffs in the packet before go, and bring the tag mechanism into the repo template or record where the candidate rendering lives.

**Preflight corrections.**

- **Step 4 replaces the Traefik allocation; it is not a hot route change.** A template-text change is a destructive update in Nomad. The README's "no restart" claim applies to Consul data changes, not template edits. Expect the listener check to go critical and back. Run `nomad job plan` first, require one create/one destroy and no port-collision warning, then wait on the new allocation before the browser reload.
- **Step 3 places all eight allocations at once.** Scaling 0 to 8 is placement, not update, so `max_parallel=1` does not throttle it. The consensus-ready check needs quorum, so all eight must reach root-synced within the 15-minute healthy deadline or the deployment fails with `auto_revert=false` and allocations left in place. The plan should state this expectation and its abort path.
- **Certificate change at the preserved origin is unverified.** The client cert is node-generated (`certfile = ""`); the packet has no sources, so I cannot tell if it is persisted on the volume. If it changes, the "ordinary browser reload" meets an interstitial first. Capture the served certificate fingerprint now and compare after step 4. Storage survives either way since the origin is unchanged.

**Sequencing recommendation, Yan's call.** The plan combines a whole-fleet quorum loss, a cold consensus restart, and the image change in one step, and its rollback is another fleet-wide deployment. Alternative: stop only allocation 0 (`nomad alloc stop`), plan the ingress, and if the replacement happened to re-pick 30519 (about 1 in 12,000, detected by the plan) stop it again. Then reserve, activate, validate the origin on 259, and roll 260 through the ordinary one-at-a-time update behind the ingress. That keeps quorum, isolates each change, and is what the README designed the frontend for. It deviates from one README sentence (reserve before any replacement), so it needs your decision rather than mine.

Material limitations: the template sha256 in ingress-scope is unverified (no hashing tool), the Nomad node id to conrad mapping is taken from the plan, and I could not run the stop notifier since this session has no shell tool.
