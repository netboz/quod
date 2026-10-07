# Network-scoped browser reference release

The fix is commit `1a093d10abbacac6eceeb4dfde47cc0d98b6a395`.
The separate release label is commit
`3a97d47155419a24f038c7425bea2c24ddf1491a`.

Image `0.7.253` was built from that clean committed tree, published without
overwriting a registry tag, and pinned to digest
`f8e8776060180b0206490817fa72894caa709c8b60b743a6a1a6d3a49d7a4395`.
Every explorer file extracted from the release image matches the frozen
source manifest.

## Verification

- Client: all 13 test files passed.
- UI lint: exit zero with the two existing Fast Refresh warnings in
  `Console.tsx`; production TypeScript/browser build passed.
- Clean sequential campaign 03: EUnit 3,768 tests, zero failures; Common
  Test 146/146; xref and Dialyzer passed. Every gate has its true child exit.
- A copied old browser profile authenticated to the fresh root, showed an
  enabled Create account button, removed the obsolete global v1 reference
  store, and stayed on Create account after reload. Both the built UI and
  deployed UI passed this check. No account or lobby was created by it.

`validation-logs.tar.gz` retains the full logs, Common Test reports, and
unsuccessful predecessors. Attempt 01 could not bind a loopback socket in
the sandbox. Attempt 02 was interrupted and has no success/exit claim.
Campaign 03 ran with loopback access on the same committed tree. The first
read-only deployment preparation also stopped on an incorrect assertion
that the candidate had the main job's vault-init task; its inputs and stop
reason are retained. The corrected candidate plan changes exactly three
image references and makes no other job change.

## Deployment

Only `quod-finality-candidate-v6-20260926` was upgraded. The single submission
used check index `827417`; the resulting job version is 51, deployment
`91de89a8` completed successfully, and all eight allocations are healthy
with zero task restarts. All nodes report version `0.7.253`, the original
clean root anchor, 18 ready system ontologies, zero rejected catalogue
rows, and complete enrollment with stored actor pointers and committed
self-hosting facts. The main `quod` job remained at version 246 and modify
index `826727`; `main-job-unchanged.json` records the comparison.

The browser check verifies clean signup entry, not a newly created human's
lobby or source inspection. The earlier live modelling-source proof and
requested Fable review remain in the parent evidence directory. Old
manually added v1 references are intentionally discarded; network-scoped
accounts can return from the encrypted identity provider.
