# Real pre-C2 ledger bytes (refusal fixture only)

Copied without modification from the stopped, real six-namespace lab fixture
frozen at `/tmp/quod-L2-s7-kmzysg/old-data` on 2026-09-11. No private keys or
identity files are included. The four files are the source and target ledger
segments and signing journals, not hand-built magic-header examples.

Old code: slice 6 `1d8da2e`, with the then-staged label-only .163 bump.
`chain_b` contains genesis, agent-key admission, a signed source claim and its
receipt (height 4). `chain_c` contains genesis and the signed target application
(height 2). The signed goal was `chain_c::assertz(slice7_old_format_witness)`.
The old-side probe verified every ledger certificate/history transition, exact
anchors, actual target fact, terminal source receipt, and both QSJ3 recoveries.
It checked stable owners before their orderly shutdown. The frozen generation
source, metadata, full logs, true exit 0 and source hashes remain in that archive.

The permanent refusal test pins SHA-256 for every byte before copying to its
own temporary directory. It requires named V5 and QSJ3 refusals from new code,
including read/write opens, and checks no file was truncated or altered. No
legacy decoder or migration writer is present.

`direct_effects.qej` is a separately generated real QEJ1/snapshot-6/row-5
journal, written by old production `bind_operation/2` around a canonical
signed source submission. Old code reopened its `operation_pending` row and
left all 6,976 bytes unchanged. This is a preparation/author-anchor protocol
fixture, not a full consensus run or an executed effect. Its generation source
and true-exit log are in `/tmp/quod-L2-s7-impl-fnctAZ/old-effect*`. The permanent
test pins its SHA-256 and requires `unsupported_effect_journal_format, 1`
without altering the file. No real identity key or deployment template is used.
