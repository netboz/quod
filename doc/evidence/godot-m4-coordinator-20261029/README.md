# M4 independent coordinator verification

This is subsequent coordinator evidence for the preserved candidate09/final06
boundary. It does not rewrite the worker's frozen evidence or establish full M4
acceptance. See the [verification handoff](../../../nimbalyst-local/handoffs/godot-m4-coordinator-verification.md).

- [Boundary verification](boundary-verification.json): all129 artifact hashes,
  exact live and reconstructed23554-entry source sets, binary patch and actual
  output archive contents/path sets/modes.
- [Independent complete reconstruction](own-reconstruction.json): real binary
  patch application and every source content/link/mode checked outside checkouts.
- [Campaign verification](campaign-verification.json): own-UUID metadata reads,
  final91 client inputs/196 outputs and all11 true-exit/log receipts. The
  historical progress receipt predates the later final idle boundary.
- [Final session/queue boundary](session-boundary.json): idle writer and both
  known queued prompts completed; full list-only inspection, no consumption claim.
- [Source audit](source-audit.json): all44 per-file line counts recounted.

The failed reader attempts and their exact scripts are retained as
`boundary-verification-attempt01.json`, `verify_boundary_attempt01.py`,
`boundary-verification-attempt02.json` and `verify_boundary_attempt02.py`.
They concern Git provenance and archive-directory schema interpretation. The
corrected [verifier](verify_boundary.py) checks those separately.
[Preservation syntax error](preservation-command-syntax-error.json) records a
separate command that failed before execution. None required product changes
or product test reruns. The file index hashes these subsequent coordination
artifacts; it is distinct from the worker's immutable snapshot index.

Acceptance remains held for the two unresolved process-exit stalls and native
OpenXR/physical qualification dependencies. No commit, tracker body publication,
full-M4 credit or M5 launch is established by these receipts.
