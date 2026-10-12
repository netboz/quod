# Candidate 0.7.263 deployment

Release 0.7.263 is deployed and healthy on the existing eight-node candidate.
The same personal world and its history are retained. No refound was needed.

Implementation: `5aa6feb348504f18bfb4fc814b21c1c308b7fced`.
Separate release label: `f949d1c4632d42dd91d1a10176869237948a60e0`.
The [committed-input check](committed-inputs.json) verifies all 1,036 frozen
gate05 inputs and the tested Explorer assets against that commit.
All [eleven clean sequential gates](../release-263-gates-05/README.md) passed,
including 34 native tests in each profile, 3,884 EUnit tests and 146 Common Test
cases. The requested Opus 5.5 plan and implementation reviews, independently
checked corrections and earlier failed candidates are retained separately.

The exact committed image passed an isolated, network-disabled boot check and
retained all 176 tested browser asset hashes. Its [verified image receipt](verified-image.json)
records:

`192.168.1.11:5000/quod:0.7.263@sha256:fcac30fe64e954ad09459b1ac2804305d2703d0e0d8761f9708320dbc9b528c2`

The existing single-writer workflow submitted one indexed maintenance
transition, then one indexed release transition. The [exact comparison](candidate-exact-diff.json)
permits only maintenance count 8→0 and the five pinned image substitutions for
release. The retained volumes, placement, services, configuration and stable
browser ingress are unchanged. The prior job and image remain the explicit
rollback target; automatic rollback is disabled. No uncertain write was
resubmitted, and no write or refound remains queued from this scope.

Candidate job `quod-finality-candidate-v6-20260926` is version **71**, modify
index **847862**, deployment `e45ff376-79fd-ad35-cde6-42b65938cf9f`.
The [real-owner fleet probe](fleet-probe.json) found all eight nodes on 0.7.263,
with zero restarts, retained principals, ready vaults and 18 ready system
ontologies. Their retained root is
`E9A485A929BE605DC01E1BBA7820AD956F84DE6B502C24D1B45A5D4819111096`.
The separate main job remains version 246 / modify index 826727.

The [history comparison](history-after.json) preserves both personal anchors
and the recorded blocks at human heights 350/358 and world heights 176/186.
The world advanced from 186 to 188 through ordinary authority recovery; the
human remains at 358. Its [physics owner](personal-owner-after.json) is active
and navigation-ready, structure 1, generation 5, with one initial installation.
This world has no rest or hinge checkpoint inputs; none were substituted.
The browser origin and TLS certificate are unchanged.

After the [actual signed desktop acceptance](../desktop-263-01/README.md), the
final read-only [receipt](PASSED.json), at 02:03:33 UTC on October 12, confirms
the same eight healthy allocations, zero restarts, unchanged main/ingress,
unchanged personal anchors and retained blocks, and the same current heights.

[Full evidence](evidence.tar.gz) contains 110 files: scripts, complete build
and boot logs, original preflight reads, mutation requests/results, true child
exits, rollback body, deployed-owner reads and final history/health checks.
The [manifest](files.json) records hashes and verified archive contents.
Duplicate image build trees are excluded. This archive contains the compiled
boot probe and source; browser private keys and profile data are absent.
