# Revision 03 — unapplied review proposals

This revision responds to the consolidated Claude Fable review and the parent's
independent source checks. **Nothing here authorizes application.** No proposed
runtime or test source has been applied, compiled or executed. Current production
is still `applied-presentation01` (+68/−161); this revision's actual production
delta is **+0/−0**. Revision 02 artifacts and presentation freezes 01–03 remain
unchanged. The two automatic approval rejections remain in force.

The reviewer found no applied-slice defect requiring another presentation edit.
Its initial attribution-regression and dead-unlimited-branch claims were withdrawn.
Its claimed heap experiment is **not accepted execution evidence**: see the
[parent's correction](../inputs/claude-heap-probe-evidence-correction.md). The
original [review](../claude-fable-review.md) is preserved literally.

## Shared boundary correction

Apply only after the parent obtains the required explicit authority, as one
consistent source/test/doc set:

- `nested-goal-owner.patch`: **+10/−15, net −5**. Retire the duplicate nested
  128 KiB quota in scope, transcript and authorization owners. DTX and ask decode
  transcript goals under their already-admitted complete plan envelope, not
  `byte_size(Blob)`. Canonical-encoding failure reports `protocol_error,bad_payload`,
  not the now-false `too_large,goal`. Exact selection, caller chain, principal,
  authorization reproving, cancellation, plan admission and deadlines remain.
- `presentation-reply-owner.patch`: **+102/−184, net −82** (includes conditional
  TEST wrappers for the existing router functions). Retire result/view subquotas,
  remove dead size-error branches/specs, and validate normalized results without
  serializing just to count bytes. Endpoint encode/decode retains explicit
  complete-envelope refusal against the **existing 1 MiB transport policy**.
  The router turns that refusal into the existing public `result_too_large`
  result, preserving the exact request/cursor tuple. It sends one error response;
  it does not resubmit execution, mark the operation pre-execution-refused or
  fabricate an uncertain/committed outcome. Malformed normalized results retain
  `proof_unavailable`, rather than being mislabeled as size failures. Pending
  and committed outcomes that fit the carrier retain their existing shape.
- The same reply patch closes **all** current production/test callers of
  `QUOD_CLIENT_GOAL_MAX_REPLY_BYTES` and `MAX_ENVELOPE_BYTES`, including terrain.
  `quod_terrain_wire` becomes encoding only: remove `admit/3`, `batch/2`, byte
  counting, prefix selection and the legacy macros. The existing physics owner
  retains its exact snapshot and requested indices and delivers the complete
  requested set once per credit. The view decoder and browser retire `through`
  acknowledgements. Exact completion, watch/token/interest fences, finite measured
  allowances, digest validation and retained unchanged resources remain. This
  changes presentation delivery, not terrain generation, physical admission,
  space identity, Stage 3 domain semantics or permissions.
- `presentation-docs.patch` replaces the obsolete batching/latency contract in
  the existing physics specification. Complete-set delivery promises no latency
  bound; no replacement population/byte cap or batching workaround is proposed.

Combined required production proposal: **+112/−199, net −87**. Separate proposed
tests: nested **+56/−15**; reply/router/terrain **+131/−112**. No new production
numeric budget or changed timeout is present. Numbers in fixtures cross retired
boundaries or specify explicit test-owned finite policy; they are not defaults.

## Optional policy choice: shared-binary accounting

`optional-shared-binary-owner.patch` is **+9/−2, net +7**, independent of whether
Yan approves the boundary retirement. It changes what finite `heap_bytes`
allowances measure, so it needs an explicit policy choice. It installs
`include_shared_binaries => true` at the existing proof installer and reads the
VM's current heap blocks and binary virtual-heap counters for initial admission.
It does not sum or deduplicate `process_info(binary)` references, add a registry,
copy binaries, change defaults or force GC. Optional tests are **+60/−0**;
the optional specification patch is **+8/−1**.

The source basis is the saved, hashed **OTP-28.0** files under
[`inputs/otp28-accounting-source`](../inputs/otp28-accounting-source/sources.json):
`erl_gc.c:3617–3704` exposes the same young/old binary word counters that its
maximum-heap check adds. `erl_bif_info.c:2094–2103` exposes these through
`garbage_collection_info`. The initial quantity is the sum of heap block, old
heap block, message-buffer, young binary and old binary words, multiplied by VM
word size. No separately summed stack or binary reference list double-counts
that quantity. This is source verification, **not an executed measurement**.
The [upstream OTP-28.0 GC source](https://github.com/erlang/otp/blob/OTP-28.0/erts/emulator/beam/erl_gc.c)
is the exact inspected version, rather than an inference from current master.

Finite overrides would charge a shared binary in each referencing worker; a
slice can retain its parent's allocation. VM accounting is not unique logical
payload bytes or RSS: binary reference nodes, word rounding and VM-managed
off-heap objects follow VM rules. The initial counters are a point-in-time
snapshot, not the next GC's peak. Later enforcement happens at collection and
includes collection allocations; allocation can precede enforcement. No promise
of an immediate allocation firewall is made. Bootstrap `unlimited` still installs
size zero, with no finite ceiling. These implications follow the
[OTP 28 process-limit contract](https://www.erlang.org/docs/28/apps/erts/erlang.html#process_flag/2)
and the inspected implementation; runtime receipts remain required.

If Yan keeps heap-only semantics, omit **all three** optional artifacts. The
required boundary proposal must not be justified by claiming heap-only policy
covers shared binary bytes. Authored co-hosted nested goals then have no separate
binary-byte quota; they remain within the existing trusted execution boundary.
Answer policy measures each canonical answer, not total resident memory or the
aggregate of many answers. Result/JSON serialization runs outside the proof
worker; even the optional heap change is not an allocation cap on those processes.
Remote carrier refusal remains separate from all these resource semantics.

## Proposed verification and its limits

`verification.json` records eight read-only `git apply --check` exits **0**, both
stdout/stderr EOF and exact patch/log hashes. A source-overlay search finds no
remaining callers of the three retired macros or terrain `admit/batch` in current
product/tests. Every original source matches its recorded hash; all ten applied
product hashes and previous archive/manifest hashes are unchanged. Applicability
is neither compilation nor behavior acceptance.

After approval, proposed tests exercise the actual router send seam and its real
outbound correlation owner: oversized answer/cursor/committed responses yield a
correlated terminal size error, invalid results keep their own error, finite
material errors and pending/committed outcomes survive, and a late response cannot
restore a cancelled correlation. Existing wrong-peer, malformed-envelope,
signature-denial, uncertain-operation and route-expiry tests remain necessary.

Nested tests carry a 160000-byte binary through real scope authorization and DTX
transcript sealing/decoding, preserve denied goals without executing them, and
check cancellation plus malformed-term refusal. The existing real producer's
finite `answer_bytes` test is extended to that size; exact allowance, allowance
minus one and zero remain checked. Existing policy pinning, initial heap refusal,
GC kill, full-plan refusal, authorization replay and no-I/O renewal tests remain.

Terrain proposals replace quota-only tests with full content/manifest identity
checks, a signed large resident selection with exact payload/digest agreement,
stale completion refusal, browser atomic set verification and stale-interest
withdrawal. Existing finite cost, missing/duplicate/unrequested/digest refusal,
reconnect, no-I/O retention and source-revocation checks remain required. The
optional tests separately cover real installer flags, unlimited/zero policy,
finite GC killing and parent-binary charging through initial proof admission.

The prepared full signed `LimitsChecks.cs` campaign is still **unexecuted** and
the large catalogue remains **unaccepted**. Its denial/revocation, stale selection,
real update, cycles, reconnect and unchanged-work counters must pass on approved
source. Earlier D5/editor evidence is not relabelled. No new review was launched.

General 1 MiB network admission, structural depth, parser and other signed-ingress
policies remain disclosed separate policies, not intrinsic encoding capacities.
No catalogue/layout optimization, direct-local introspection, deletion semantics,
founding, D6 clause identities or Stage 3 integration is included.

Artifact preparation retained one harmless failed edit attempt: `apply_patch`
reported `Failed to find expected lines` for the proposed documentation transform;
no files changed in that attempt. A precise context edit corrected the generator.
An initial sandboxed upstream-source read failed with DNS `URLError`; an authorized
read-only network fetch then saved the official source. Neither was a runtime
test or a replay of the rejected production action.
