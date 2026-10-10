# Corrected shared geometry prerequisite

This supersedes the implementation-scope details in `implementation-geometry-01.md`
without replacing its frozen review or validation evidence. The full feature is
not implemented. The user approved explicit source-owned retained-projection
delegation and reiterated that no compatibility implementation is required.
The new existing-owner capability proposal is at the task's architecture gate;
no capability-evolution code or live transition has been implemented.

## Checked Fable findings and corrections

The first implementation review returned exit 0, used `claude-fable-5-1`, and
changed none of 52 frozen inputs. It correctly found that the shared posed-body
schema relaxed the hinge's supported pose restriction. Door authoring now checks
one shared hinge-definition guard: vector baseline and box frame/leaf. Native
installation rejects authored frame or leaf rotations before creating the joint.

The shared body schema now enforces the adapter's finite binary32 envelope for
density and millimetre/milliradian integer fields, without an arbitrary angle or
population ceiling. The exact integer maximum was computed with Python's
binary32 decoder. Coordinate allowances remain Prolog policy. Motor scalars use
the same positive finite encoding guard. Native mass, volume, triangle-area and
compound-bound validation remain adapter obligations.

Actions identify invalid bodies and coordinate-allowance failures through the
existing `fail_with_reason` mechanism. The duplicate relocation coordinate
check is removed; relocation still requires vector input and preserves authored
rotation. The unsigned-32-bit index guard remains: `Index < Count` alone does
not imply that an index fits its encoding. Native decoding also checks this
representation requirement independently.

Nine installed-owner signed edit cases cover all six supported geometry forms,
including dynamic ball/convex and controlled capsule cases in explicitly authored
zero gravity. Refusal tests cover malformed geometry, unsupported kinds, huge
density/rotation, part-pose range, body identity encoding, coordinate allowance,
rotated hinge authoring and non-box hinge definitions. Native tests reject both
rotated frame and leaf and prove that the existing adapter retires failed
installation resources. Refusal precedes mutation; the test name now states
that committed state remains unchanged rather than claiming rollback of a
write which never occurred.

Production delta: Prolog +67/-13 and native adapter +2/-0, net +56 lines.
Documentation adds 9 lines. Tests add 125 lines, including redacted caller
attribution for unchanged-work failures. The growth is the shared supported
schema/encoding contract and an explicit native hinge guard; there is no new
owner, domain engine, broker, module-loading branch or mutable geometry store.

## Retained validation and measurement caveat

- `geometry-03`: 12 tests, one failure, child exit 1. The native guard correctly
  rejected the rotated frame; the test expected an empty joint list after an
  error. Existing `access/3` retires that resource. No adapter behavior was
  weakened to accommodate the incorrect expectation.
- `geometry-04`: asserts retired hinge/body samples; 12 tests, zero failures,
  child exit 0, source hashes unchanged.
- `owners-geometry-02`: 178 tests, one failure, child exit 1. A global zero-I/O
  trace observed one `file:datasync/1`; it omitted process/caller attribution.
  Failed fixture `/tmp/quod_hosted_5ACD1547E17440CD` remains intact.
- `geometry-io-diagnostic-01`: caller/PID/registry keys added, argument values
  redacted, strict zero-I/O assertion retained; 9 tests, zero failures, exit 0.
- `owners-geometry-io-diagnostic-01`: 178 tests, zero failures, exit 0, hashes
  unchanged. The production tree is identical to the failed broad run. This
  diagnostic run did not reproduce or explain the earlier sync observation.
- `trace-negative-control-01`: the exact trace match specification detected one
  deliberate temporary-file datasync with caller attribution, child exit 0.
  No namespace, ledger or native world was touched.
- `git diff --check` passed.

The unattributed sync remains a measurement caveat. Passing diagnostic runs are
not evidence that its cause was resolved, nor acceptance of remote invalidation
or unchanged remote-work cost. Those full-feature measurements are still open,
along with the signed current-lobby baseline and desktop collision acceptance.
