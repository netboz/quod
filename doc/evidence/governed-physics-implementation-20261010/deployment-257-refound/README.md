# Candidate 0.7.257 release and ledger refound

Yan explicitly authorized “commit and deploy, refound ledgers”, then “just wipe
content and redeploy”. This operation reset the candidate ledger history. It
supersedes preservation of that old history for this release; physical acceptance
still requires a fresh signed personal-world identity/history baseline.

The sole target was `quod-finality-candidate-v6-20260926`. The separate `quod` job remained
at version 246 / JobModifyIndex 826727.

## Committed release and clean gates

- Implementation: `7e7abf340b60d599115f6da1010d8d483d1c3ab7`.
- Separate version label: `7671aafa4d50a1ec800585b8e3dc3400b7dc3331`.
- Immutable image: `192.168.1.11:5000/quod:0.7.257@sha256:4e8ccb4452c88b5a03bc0791dde8b251685685e473ce2f09b0503db05b029f88`.
- Source manifest SHA-256: `6b1f59490fc9b479d1f013d4c3a29324518a5c1f8289fb8b4265e9ae224d445e`.
- All ten sequential release gates passed on the exact committed tree:
  native tests/Clippy, client tests, UI build/lint, 3,858 EUnit tests with zero
  failures, 146 Common Tests, xref, Dialyzer and the production release build.
- The 176 generated browser assets match the committed inputs and packaged image.
  Uncommitted sibling native-client and documentation work was excluded.

Campaign `gates-01` was interrupted during EUnit with no true child exit.
Its logs and stop marker remain in `gates-01-logs.tar.gz`; it was never treated
as passed. Separately labelled `gates-02` ran under a local user service so editor
interruptions could not terminate it. Its full logs, child exits, frozen input
hashes and Common Test logs remain in `gates-02-logs.tar.gz`.

## Destructive refound and runtime checks

Eight new empty volumes were created in `quod-finality-candidate-v6-20260926-refound-20261011-v4`.
A checked-index bootstrap replaced candidate version 57 with one fresh founder.
After the founder was running and every old allocation had stopped, all eight
recorded old volumes in `quod-finality-candidate-v6-20260926-refound-20261010-v3` were deleted. The final inventory
has eight ready new volumes and no old family member.

The fresh root is `07D3A165757A429C29FC2345A31195B5AB512E93CDFF0359D7ABD1D712BAC7D0`. Ordinary governed root actions, ontology founding,
node enrollment and the existing catalogue created and published 18 system
ontologies. No separate physics ontology or special space path was introduced.

Deployment `64e84c78-089c-f890-5f4e-5e677477cbed` succeeded at candidate version 59 /
JobModifyIndex 842921: eight desired, placed and healthy allocations,
zero unhealthy allocations and zero task restarts. The production-owner probe
on every node verified release 0.7.257, the exact fresh root, committed/applied
root height 71, 18 ready catalogue entries, zero rejected entries, completed
node enrollment, a stored principal pointer and committed self-hosting.

A fresh ephemeral key-bound signup principal exercised the existing signed
client protocol at `https://192.168.1.10:27972`. It read all 17 public ontology sources,
repeated an unchanged read and verified denial for a wrong anchor, the private
root and an unauthorized policy invocation. It submitted zero ledger writes.
TLS verification was disabled only for the self-signed LAN endpoint; this checks
application signatures and authorization, not certificate verification.

`deployment-logs.tar.gz` retains the exact scripts, build/push receipts,
checked-index plans/submissions, volume receipts, original action intents,
founding anchors, fleet probes and signed-client evidence. Adjacent JSON files
expose the principal results; `manifest.json` hashes this evidence folder.
The seal was recorded at 2026-10-10T23:56:29.985755+00:00; no further remote mutation was made
by this release owner.

## Acceptance still open

This release proves deployment and refounding. It does not establish a signed
personal-world baseline, real remote collider installation/work measurements,
or actual desktop collision acceptance. The generic physics tracker remains
open. Vive/WebXR and durable blocked-door acceptance remain separate obligations.
