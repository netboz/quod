# Complete source inspection deployment — 0.7.254

The user explicitly directed a ledger purge and clean redeployment. No
retained-ledger migration was submitted. The candidate fleet's eight stopped
host volumes were deleted through Nomad and recreated empty on their previous
compute nodes. The separate main `quod` job remains version 246, modify index
826727.

Image `0.7.254` is pinned to
`sha256:b4f050064617ff5cd2e22d4c3d7ec9cee3c56be1ffcfc6ca0ab3b5534059c323`.
The release contains the validated implementation and browser assets; only the
two release labels were changed afterward. It was built from a frozen manifest
of uncommitted source based on `0e5b887716bd2cce0b94d45b2dc25fec2fdfd739`.
No git commit is claimed. Extracted browser assets match the frozen inputs.

The existing clean-refound procedure installed the packaged ontologies through
`create_ontology`, ordinary signed transactions, node enrollment and exact signup
hosting delegation. No bespoke migration or history rewrite ran. The new root
anchor is `D0100AE71106BBFBF381794B68C6D141111E29415BB636FD10897D52541CBBCE`.

## Verification

- Candidate job `quod-finality-candidate-v6-20260926`, version 54, deployment
  `affff327-2130-b43b-16f1-106aea724c8b`: successful, eight home nodes, zero cloud nodes.
- Every node reports `0.7.254`, the same root, 18 ready system ontologies,
  zero rejected catalogue rows, completed enrollment and stored actor pointers.
- Real signed HTTP source cursors inspected all 17 public system ontologies as
  an authenticated key-bound signup applicant with no administrator grant.
  Complete domain/shared/policy content and an explicitly selected policy
  predicate were visible. Wrong anchors, private root source and policy
  invocation were refused. These checks made zero ledger writes.
- An intentional gateway-task restart recovered exactly the same source hashes
  for all 17 targets and retained the authorization refusals. Its one task
  restart is intentional; the other nodes have zero restarts.
- The actual deployed browser at `https://192.168.1.10:31609` authenticated an
  old profile to the fresh root and showed an enabled Create account button,
  including after reload. It did not select an obsolete lobby. No account was
  created during the smoke checks.
- The current tree's 352 image inputs still match the deployed frozen manifest.
  The standing clean tests remain those in the parent validation receipt:
  3,769 EUnit, 146 Common Tests, 110 client tests, browser acceptance, UI
  build/lint, xref, Dialyzer and release assembly, all passed.

[Deployment logs](deployment-logs.tar.gz) retain the commands, exact child exits,
Nomad events, purge/recreation receipts, founding outcomes and signed-read
results. Read-only preparation first failed in the sandbox; a rendering check
also referenced the wrong volume-map key and stopped before submission. Both
are retained. Automatic approval review initially rejected the image push as
an unverified destination. Read-only checks proved the registry digest matched
the existing live Quod deployment and internal Nomad registry job, and the
subsequent request was approved.

The clean network has new ontology identities; account creation starts afresh.
Implementation and release-label changes remain uncommitted.
