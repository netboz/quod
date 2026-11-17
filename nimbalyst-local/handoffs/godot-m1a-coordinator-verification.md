# M1a coordinator verification — 2026-10-28

M1a is accepted as the qualified server checkpoint within [QUO-62](nimbalyst://QUO-62).
This accepts its exact source/evidence boundary; Godot M1b and full M1 remain open.
The implementation is uncommitted. No implementation changes, gate reruns,
additional review, commit, push, deployment or main-checkout mutation were made
during this verification.

Coordinator: `ed9cd520-b2a4-4607-a8f5-ff99d08f3e46`.
Finished implementation writer: `922c7c06-1acb-4c2b-9141-fccf4ab4c947`.
Worktree: `/home/yan/src/quod_worktrees/pearl-stone`; branch: `worktree/pearl-stone`.
HEAD: `d027f9f65bbce2f484f906c92bf07ebaa4669c38`, Yan's M0 commit.
Original branch base: `f6c29fe925e666dd68ee7fa68c0e03f5d03391a2`.

The [worker handoff](godot-m1a-result.md) and
[evidence index](../../doc/evidence/godot-m1a-20261027/README.md) describe the
scope and retained failures. The immutable external boundary is
`/tmp/quod-godot-m1a-handoff-922c7c06-20261028-01`:

- Snapshot SHA-256: `f8f4eab927e5555acae573dacdc5e0d9c1fea1377181193ba06857e726f7e8d0`.
- Binary HEAD patch SHA-256: `7d773e88503761b6771a631b17fd4e4f120cd3906778dd373181c65b6d3e18d9`.
- All 17,532 live and materialized source entries match their hashes/links and
  exact source path set. The live binary patch equals the preserved patch.
  Every snapshot artifact hash, all 591 untracked archive contents and all
  1,094 dependency archive contents match. Reconstruction instructions and
  the successful source/dependency reconstruction receipt are preserved.
- All 1,426 authored inputs match both live and qualified stage source.
  All 1,094 dependency stage inputs match, with symlinks checked by target.
  All 2,053 recorded compiled outputs, 24 dependency apps, derived indexes,
  runtime/common sources, locks, native/package outputs and provider-specific
  founding/post-CT/release objects match their recorded hashes.
- Real receipts identify six exact catalogue rows plus root, eleven history
  profiles, fifteen founding sources and two distinct U/A/S0 accounts.
  All founding-source and declared EUnit module hashes match. Public-identity
  evidence is bound to the canonical receipt digest; original U/A keys differ.
  The eighteen archived Prolog originals match HEAD byte-for-byte. Relocation
  is not reduction.
- All 688 tracked M0 evidence files remain identical to committed HEAD.
  `git diff --check` passes. Final native56, EUnit4,252, CT149, xref,
  Dialyzer and local production release receipts have true exit0, no timeout
  or unrun gate, unchanged source and sequential start/end times. Native,
  EUnit and CT full-log summaries agree with their test counts.

These were read-only checks of source, artifacts, receipts and relevant
implementation/behavioral tests, not a fresh test campaign. One initial reader
incorrectly tried to compare an ignored Godot-generated `.godot/.gdignore` file
to HEAD. Restricting the M0 comparison to tracked evidence corrected the reader;
no implementation or qualification evidence changed. The separate retained M1a
consistency-reader failure and exact EUnit-object reconstruction remain labeled
as the worker recorded them. The
[machine verification receipt](/tmp/quod-m1a-coordinator-verification-ed9cd520.json)
records the coordinator's hash checks.

The signed setup, immutable custody receipt, Prolog policy and existing atomic
transition preserve distinct U/A and original parentless S0 in selected existing
account storage. The scope-token correction stays in the existing scope owner
with invalidation on foreign work/reentry/frame/restore; it does not change
protocol, deadlines, budgets or controller authority. The foreign imported
initial-occupant refusal and completed S0 later entry/admission limitations are
explicit. They are not claimed delivered. Optional machinery is preserved.
The one requested Fable review is complete and its authorization consumed;
later corrections have independent final qualification.

[QUO-62](nimbalyst://QUO-62) remains in-review/44%, four of nine checks credited.
[QUO-60](nimbalyst://QUO-60) remains in-development/17%, with M1 unchecked.
No full-M1 or desktop/XR/Vive acceptance follows from the server tests.

## Tracker publication limitation

The coordinator's new additive verification updates also failed collaborative
publication for both existing items. Each outer response was `isError:false`,
but nested `bodyWrite` reported:

```json
{"status":"failed","itemFieldsStored":true,"localSnapshotStored":true,"collaborativeBodyStored":false,"message":"The item fields and local body snapshot were saved, but the body was not stored in collaborative tracker content. Retry the body write before treating it as available to collaborators."}
```

The single API-directed body-only retry failed identically for each item.
No further retries, app rebuild/restart, database access or token workaround
were attempted. Local reads do not establish shared publication. Exact bodies
and responses are retained outside the source snapshot:

- [QUO-62 update](/tmp/quod-m1a-coordinator-update-QUO-62-result-ed9cd520.json)
  and [directed retry](/tmp/quod-m1a-coordinator-update-QUO-62-body-retry-result-ed9cd520.json).
- [QUO-60 update](/tmp/quod-m1a-coordinator-update-QUO-60-result-ed9cd520.json)
  and [directed retry](/tmp/quod-m1a-coordinator-update-QUO-60-body-retry-result-ed9cd520.json).

This is a shared-publication limitation, not a block on independently authorized
M1b implementation. The shared tracker remains canonical; this file is an
evidence/handoff record, not a second master plan.

## Issued continuation

[Ready-to-run M1b prompt](godot-m1b-prompt.md): `/planning-implement QUO-62`,
actual launcher model `openai-codex:gpt-6.1-sol`, effort `xhigh`, per Yan's
overnight steering. The finished M1a worker retains serial launch ownership.
This coordinator has issued the prompt without launching a second writer.
These two coordinator handoff files are later additions outside the M1a snapshot.

M1b owns the clean Godot identity/unlock, generic keyboard/mouse GUI and
Save/Reset U→A journey, subscription/cancellation/recovery and black S0
presentation. No new commit, deployment or Claude-review authority is granted.
Potential QUO-63 continuation stays behind full-M1 evidence verification and
the next concrete coordinator prompt. Yan need not approve unchanged routine
steps already authorized by the overnight instruction.
