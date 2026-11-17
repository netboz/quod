# M4-R1 coordinator verification — continuation stopped at unresolved acceptance

Coordinator `ed9cd520-b2a4-4607-a8f5-ff99d08f3e46` verified the complete bounded
diagnostic handoff for [QUO-65](nimbalyst://QUO-65). The evidence is preserved and
internally consistent. **Neither original shutdown failure is resolved; full
M4 acceptance, commit and M5 advancement remain held.** The autonomous serial
chain stops here for the concrete correctness and runtime dependencies below.
No need for a model stronger than the existing Sol/max was demonstrated.

Worktree `/home/yan/src/quod_worktrees/pearl-stone`, branch `worktree/pearl-stone`,
HEAD `293cf6115c0a6b18315eccdbb42cbca396f443d3`, parent
`f716ddf5e578df957a5b18421a0727a32c634f87`. The sole writer
`ca84d4f8-ccee-4ff9-9336-9cf3e9040a1f` is idle, not waiting for input. Full
list-only inspection found all three known instructions/reports completed and
no pending/executing finding. No inbox consumption API was available or claimed.

## Exact source and artifact boundary

Read the [R1 result](godot-m4-r1-result.md),
[diagnostic plan](../../doc/evidence/godot-m4-r1-20261029/diagnostic-plan.md),
[qualification](../../doc/evidence/godot-m4-r1-20261029/qualification.json) and
failure/source-quality records. The frozen boundary is
`/home/yan/.cache/quod-m4-r1-artifacts/quod-godot-m4-r1-handoff-ca84d4f8-20261029-01`.
Snapshot SHA256:
`5a09fda58101a38d362c5e50cd9bcd4f827dcca74295abaa3b1f521c95379fcc`.
Binary HEAD patch SHA256:
`8d759963b1100714e6f1301175324168bab40bdb3125a02f8b5604cefeab4370`.

The coordinator independently verified:

- All 151 indexed artifact sizes/hashes/read-only modes, including 130 actual
  predecessor hardlink identities. Boundary mode is 0555.
- Every live path, content hash, symlink and full recorded mode for 23,690
  source entries (2,993,655,953 source bytes), plus Git tracking provenance.
- The complete worker materialization outside all checkouts, independently
  hashing every one of those 23,690 paths and checking links/modes. Its audited
  verifier really applied the binary patch with child exit 0.
- All 23,554 previous M4 entries are unchanged. The 136 additions are R1
  diagnostic/evidence and subsequent coordination files. All 1,423 untracked
  source-archive payloads match the complete manifest, including modes/links.
- The exact base and tracked patch match the already independently applied M4
  reconstruction. That real prior coordinator patch proof was reused together
  with the newly checked complete untracked payload; another multigigabyte
  coordinator reconstruction was unnecessary and was not created.
- Actual output archive path/content/mode sets: 91 diagnostic inputs, 196
  exports, 344 build-output entries including 49 directories, and 414 fixture/
  provider entries. All 196 actual diagnostic export hashes and all 196 exact
  historical final04 export hashes also match their execution manifests.

The 91 live production inputs match candidate09 byte-for-byte. Only Main and
SignedView differ in the separately preserved diagnostic build; temporary
observation is absent from live production. R1 production/test/spec delta is
zero. Original production growth and all previous evidence/failures remain as
recorded by the [M4 verification](godot-m4-coordinator-verification.md).

## Diagnostic evidence and limits

All seven clean diagnostic build/core receipts have true child exit 0; the core
output records 189 checks. All four application wrappers, actual client exits
and three owned physics-server exits are 0 with completion/no timeout/error
diagnostics. Sanitized log hashes and all 60 recorded phase/task observations
were independently matched to the raw retained evidence. These checks execute
no product suites. Unchanged server gates were not repeated.

The two observed physics closes completed the managed resource chain, quit and
engine unloading. The historical final04 export also exited successfully with
its original flags. Active-backup cancellation waited for pending backup work
and resumed on Godot's main context before releasing the writer lease. These
are bounded observations of passing runs. No child survived to the diagnostic
capture deadline, so no causal stalled-process stack was captured; the capture
branch remains unexercised.

`gui-final03-backup-import` and **normal Main.CloseApplication**
`physics-final06` remain failed. The latter passed 39 assertions, then required
watchdog SIGKILL, with client -9/wrapper 1/server 0. Neither historical failure
has phase/stack evidence establishing its responsible owner. Later passes do
not make it an external/native-only issue or confine it to the old direct-quit
test path. A speculative lifecycle patch or indefinite further soak is not
justified by this investigation.

## Remaining dependencies and status

Shutdown acceptance needs a reproduced stalled process or equivalent causal
evidence sufficient to identify and qualify a responsible-owner correction.
The retained diagnostic source/drivers provide that capture seam; they are not
a fix. Separately, installed Monado exits 127 before readiness because six
required OpenCV .so.413 libraries are absent. No system/package/runtime/display
change or ABI substitute was attempted. Native OpenXR session/swapchain/profile
RID teardown and applicable QUO-27 diagnostics remain unqualified. Physical
Vive/two-wand pixels, tracking, gestures, comfort and platform exit remain unrun.
USB discovery, injected frames and desktop success do not establish them.

Fresh own-UUID explicit-project radar/get reads confirm QUO-65 in-review/80 and
[QUO-60](nimbalyst://QUO-60) in-development/67. No tracker mutation, body/checklist
publication retry, commit, new writer/review/model switch or M5 launch occurred.
Blocked shared publication remains unconfirmed; local reads are not proof of it.
Broader Stage2/D5/D6/D7 and contributing tickets remain open. All original
uncertain operations, private stores, failed measurements and snapshots remain
preserved. No new cleanup/compression or main-checkout edit occurred.

The [separate coordinator evidence](../../doc/evidence/godot-m4-r1-coordinator-20261029/README.md)
and this verification are later coordination additions outside the frozen
23,690-entry R1 set. No implementation was changed by the coordinator. No
further automatic experiment or continuation is scheduled from this decision.
