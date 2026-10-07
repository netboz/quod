# Browser candidate clean refound — 2026-10-07

This directory preserves the bounded operator inputs and receipts for the
explicitly authorized refound of Nomad job
`quod-finality-candidate-v6-20260926`. The separate `quod` job was not changed;
`main-job-unchanged.json` records its identical job version, modify index,
image, and group counts before and after the operation.

## Result

- Root anchor: `C9A6B83F8F91505F23EBACF1BF0DF92692AA890AA1060E6D5F5356D642DDA34E`
- Initial image: `0.7.252@sha256:2d7ed2e31d9b38eb88501501b8b7b39a2dc189a5438013d05ba97524839b441d`
- Fresh volume family: `quod-finality-candidate-v6-20260926-refound-20261007-v2`
- Candidate job version after scale-out: 50
- Eight home allocations healthy with zero task restarts
- Root committee: one validator, as intended for this candidate
- Eighteen system ontologies, zero rejected catalogue rows, all locally ready
- Every node enrollment complete with a stored actor pointer and committed
  discoverable self-hosting fact
- Exact signup hosting delegation committed in the founder identity
- Stable ingress health returned `ok`
- Live `quod:modelling` source probe returned `read_only`, exposed the source
  eidolon and `model/2`, and returned non-empty source

The first fresh-volume attempt is intentionally absent from this directory and
remains preserved at `/tmp/quod-candidate-refound-252-20261007`. It was stopped
after proving that `quod:node` lacked `node_identity_template/1` in genesis.
The corrected v2 helper places the reviewed `node_execution.pl` bytes in the
`quod:node` founding transaction.

## Review corrections

Claude Fable reviewed the stopped v2 checkpoint before the remaining system
ontologies were founded. Its blocker was the missing exact `quod:signup`
hosting delegation in the founder identity. The helper now commits that fact
only after the signup anchor exists. It also proves full node-enrollment
completion, rejects conflicting duplicate catalogue/policy rows, and finishes
with an 18-row, zero-rejection, all-ready gate.

The follow-up review found that the browser's global v1 agent-reference store
could still select an account from the old root. The client now stores and
selects references per root network under a v2 format and removes the
superseded v1 key. Existing accounts return from the network-keyed encrypted
identity record. Manually added v1 references must be entered again.

## Evidence map

- `candidate-refound.nomad`, `render.py`, and `scope.txt`: exact candidate
  deployment rendering.
- `quod_fresh_systems.erl` and the Python operators: reviewed one-use bootstrap
  and verification helpers. Domain writes still use existing root actions and
  ordinary ontology transactions.
- `anchors.json`, `final-gate.json`, `fleet-probe.json`: exact identities and
  final eight-node state.
- `enrollment-evidence.json`, `delegate-signup.json`, `policy-apps.json`:
  enrollment and delegation proofs.
- `scale-out.*`, `candidate-final-state.json`, `main-job-unchanged.json`: Nomad
  submission and final job state.
- `source-probe-01.*`: retained syntax-failed read-only probe.
- `source-probe-02.*`: retained assertion failure which revealed that an
  admitted node has broader target-authored inspection than an ordinary user.
- `source-probe-03.*`: corrected live source-access proof.
- `fable-review.md`: both requested review results.

No test account or personal lobby was created during verification, so the new
network remains clean for the user's first signup.
