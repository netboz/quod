# Candidate release 0.7.259

The authorized candidate refound/deployment passed on October 11. Implementation
commit `f64424b90c6816e762b8cffa2da9895704c5d946` and separate label
`a8924ed3cd6bc946dd52e696172668dc9431f4d8` match all 682 release source inputs and
176 generated browser assets. The [clean sequential gates](../release-259-gates-03/README.md)
and Fable custody-budget review precede deployment.

Pinned image: `192.168.1.11:5000/quod:0.7.259@sha256:3a48fe2b9f88350b0e874b3d2f8938f2ab86d08f3c35a464635f47a15e8f478c`.
Candidate `quod-finality-candidate-v6-20260926` reached version63/index845822;
deployment `f591c299-3c48-8e83-058e-32cbc20409f8` succeeded with eight healthy,
zero-restart allocations, all 18 system ontologies ready and policy64/unlimited
installed on every node. Main `quod` stayed version246/index826727.

Root: `E9A485A929BE605DC01E1BBA7820AD956F84DE6B502C24D1B45A5D4819111096`.
The new volume family ends `refound-20261011-v6`; the superseded v5 family was
removed under the explicit refound authorization. The read-only signed release
smoke made zero ledger writes. These deployment results do not claim personal
collision acceptance. Subsequent authorized remote-collider and personal-world
work is recorded separately; this is not a final no-further-writes seal.

[Complete execution evidence](evidence.tar.gz) preserves command intents, true
child exits, source/image attestations, bootstrap and rollout receipts, readiness
probes and signed smoke. [File hashes](files.json) cover every archived file;
duplicate build contexts, bytecode and caches are omitted. No browser profile or
private signing key is included.
