# Release 0.7.260, existing ledgers retained

Candidate deployment completed on October 11. The implementation commit is
`56883be0c25e96bb7fa91d4625e89de2217cb10e`; the separate version label is
`c483c48bc89949695d7725f6e2c9f0b741e1b723`.

The candidate job `quod-finality-candidate-v6-20260926` moved from version 63
through maintenance version 64 to release version 65. The deployed image is
`192.168.1.11:5000/quod:0.7.260@sha256:e7a4dd4c221d8b358ff7d14a3b818901ae5ae5f331158a46754a72016a76adca`.
The [fleet observation](fleet-probe.json) verifies eight healthy allocations,
zero restarts, the same node principals, and 18 ready system ontologies.
The separate main job remained version 246 / modify index 826727.

All eight existing volumes and their node placements were retained. There was
no refound. The root remains
`E9A485A929BE605DC01E1BBA7820AD956F84DE6B502C24D1B45A5D4819111096`.
The [history comparison](history-after.json) verifies the original human block
350 and personal-world block 176 exactly. Recovery appended ordinary run state;
it did not rewrite either history. The [installed owner](personal-owner-after.json)
restored the same world, bodies, geometry and authority with run generation 2.

The existing client ingress template was instantiated as `quod27-client-30519`
on conrad, retaining the browser origin `https://192.168.1.10:30519` and its
certificate. It routes only the candidate node-0 client service. Existing global
ingress jobs were unchanged. Exact requests, CAS indices, original submission
identities, observed outcomes and Nomad's subsequent no-op plans are retained in
[maintenance](maintenance/PASSED.json), [reservation](reserve/PASSED.json),
[release](release/PASSED.json), and [route activation](activate-route/PASSED.json).

Fable [review 01](review-01/fable-review.md) required the actual candidate job
bodies. [Review 02](review-02/fable-review.md) gave conditional approval and
identified a comparison defect in the operator script. The
[checked disposition](review-02/disposition.md) and
[clearance](review-clearance.json) bind the corrected operator and exact jobs.
This is independently verified disposition of the advice, not a second Fable
verdict on the corrected script.

The [archive manifest](archive-manifest.json) records the retained public
evidence. Private browser profiles, signing keys, isolated boot storage, build
contexts and generated binaries are excluded. Full clean source gates were
already committed under [gates 02](../release-260-gates-02/README.md).

Deployment is complete. Desktop acceptance remains open: the corrected client
accepted movement and console collision, but the subsequent trial exposed a
shared native floor-slide rounding defect before the roof was reached.
