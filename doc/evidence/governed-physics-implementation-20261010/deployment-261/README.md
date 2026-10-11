# Release 0.7.261: retained-ledger candidate upgrade

The native floor-slide correction is deployed. Candidate job version 67,
JobModifyIndex 846780, deployment `66bd1b36-a2c1-0d6e-bcc4-2858a543ee56`
finished successfully. All eight allocations run the pinned image with zero
restarts; all 18 system ontologies are ready. The separate main job remains
version 246 / JobModifyIndex 826727, and the stable browser ingress is unchanged.

- Implementation: `bde7b9ec5479129985fcdc277cc0011b3932efd7`.
- Separate release label: `cff6de5007728be4172d9f631aee08740e583705`.
- Image: `192.168.1.11:5000/quod:0.7.261@sha256:980cfe97ea758747df118d41196a216463c8032abf79d3ee1bc0a36a2082e378`.

All [eleven release gates](../release-261-gates-05/README.md) passed.
[Committed-input attestation](committed-inputs.json) matches all 683 source
inputs and 176 browser assets to that tested tree. Image build, isolated vault
and root startup, push and registry-digest verification passed with retained
child exits. The [verified image](verified-image.json) binds these results.

Fable reviewed the reduced operator-code packet after Yan explicitly approved
its transmission. The first two invocations were rejected by automatic approval
review before launch; their stop records remain. The
[completed review disposition](../release-261-deployment-review-03/disposition.md)
checks its three conditions against the full local job/source and rejects its
unsupported statement about running repository greps. Tools were disabled.

The guarded maintenance transition changed only Count 8 to 0 and waited for all
eight original allocations to stop. The guarded release transition restored
Count 8 with five image fields changed. Each submitted once using the exact
predecessor CAS index. The [exact diff](candidate-exact-diff.json) and
[independent audit](independent-diff-audit.json) preserve the scope. No volume was
recreated and no ontology was refounded.

[Fleet verification](fleet-probe.json) confirms the same root anchor, node
identities, eight volume identities/placements and ready custody owners.
[History verification](history-after.json) preserves the human ontology's
committed blocks 350 and 358 and the personal world's blocks 176 and 182 exactly.
Human height is 358; the world recovered to height 184. These appends do not
replace its prior history. The browser origin and TLS certificate remain the
same. The [recovered physics owner](personal-owner-after.json) is active with
navigation ready, structure 1 and one startup installation.

This establishes deployment and recovery. Normal signed desktop collision
acceptance remains a separate obligation; hardware XR and durable closed-door
consequences are not claimed here.

A later [read-only background check](background-health-01.json), performed while
Yan played another game, again reports eight healthy allocations with zero
restarts. Candidate version 67, the main job and the stable ingress remain at
the exact recorded revisions. This check did not control the desktop or submit
a deployment, domain action or runtime mutation.
