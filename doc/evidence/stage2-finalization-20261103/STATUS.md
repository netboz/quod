# Commit finalization

Yan authorized committing all pending work and pushing Erlog to his repository.
The exact pinned Erlog commit `79b3874617a4eb9f76d5089a3fc908667e605e8a` was
pushed without force to `netboz/erlog`, branch `codex/stage2-policy-diagnostics`.
A separate remote read confirmed that exact hash. The [receipt](erlog-publication.json)
records the successful push and verification. Earlier unpublished statements
remain historical delivery-state evidence; the dependency is now fetchable.
No new Erlog source commit was needed. Its generated scanner/application files
were preserved outside the source delivery.

The Quod commit scope includes pending backend, Godot, client test/tool, contract,
plan, handoff and evidence changes. Local review-packet archives, generated editor
skills, bytecode and compiled binaries remain outside Git; nothing is deleted.
This includes accumulated project evidence, not only the small predicate patch.
No Quod push, deployment, package/release, hardware or shutdown retry is included.

## Finalization checks

The predicate-removal production/test source hashes still match its exact
[final manifest](../stage2-predicate-removal-20261103/inputs/final-source.json).
Its completed tests and production compile were not repeated.

The broader current Godot source differs from its earlier shutdown qualification
in six inputs. That older run is not claimed as whole-current-source acceptance.
Fresh offline integration checks preserve full child stdout/stderr and actual
exit codes with both EOFs:

- [core](core.json), exit 1: a shared historical corpus still labelled a valid
  65-level term malformed after the parser quota was removed. This failure is
  retained. The obsolete depth-refusal row was removed from both the corpus and
  its generator; all five malformed-syntax rows remain. Existing admission
  checks prove exact 96-level acceptance and malformed trailing-text refusal.
  [Exact fixture before/after hashes](fixture-correction.json) bind the correction.
- [core02](core02.json), exit 0: 188 current offline client checks pass, including
  exact wire signatures, original identity/durability, generic forms, outcomes,
  scene frames, stale deliveries and resource verification.
- [admission02](admission02.json), exit 0: all 10 checks pass, including deep
  terms, long symbols/namespaces, large signed fields and real uint16 overflow.
- [managed-build02](managed-build02.json), exit 0: current managed Godot project
  compiles with 0 errors and 101 warnings. Warnings are retained in its log;
  this is compilation, not a native/hardware/runtime reliability acceptance.
- `git diff --check` passes.

The [driver](checks.py) records exact commands and current client source hashes.
The fresh campaign adds no production code; its only source correction is the
obsolete test-vector retirement. Existing shutdown/VR acceptance gaps and Stage 2
policy-owner work remain recorded in their own handoffs. No deadlines, runtime
limits, permissions or uncertain-operation handling were changed.

## Commit-tool retry

The initial all-file proposal failed with `spawn E2BIG` before staging or commit;
HEAD remained `b30967e33bb8d64eca3f8a093bad018549c9b8af` and the index stayed empty.
The OS could not accept the expanded 22,235-path command. A directory-path
proposal then failed with `Unexpected files were staged`; the tool requires
individual file paths. That attempt also left HEAD and the index unchanged.
The replacement groups exact paths into one source/docs/current-evidence commit
and subsequent historical-evidence commits within the OS argument-size boundary.
Ignore rules exclude generated Python bytecode directories and diagnostic DLL/PDB outputs;
these files remain on disk. Source, tests and evidence are preserved. This is a
local commit-tool transport correction, not a runtime limit or test failure.
