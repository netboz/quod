# Parent review of applied boundary refactor

This is source review and explicitly labelled evidence, not whole-tree acceptance.
The earlier presentation, proposal and failed-run freezes remain unchanged.

## Scope invocation

The applied `quod_scope_session:valid_invocation_input/3` no longer measures the
goal against the inherited top-level 128 KiB quota. It retains the 16-byte
invocation identity, nonempty exact-identity chain and transaction-selection
checks. `handle_open` still refuses duplicate invocation identities and invokes
the existing `authorize_and_open` path. Transcript, scope-wire, DTX and ask
changes remove the same retired component quota consistently; complete carrier
and plan checks remain. This is source verification, not a fresh signed result.

## Result delivery and original-operation recovery

The reviewed router correction provides a correlated result-size error when
the endpoint refuses its complete envelope. It does not resubmit execution.
However, the original HTTP mapping of this error to 413 caused both actual
client owners to treat it as terminal refusal and remove recovery evidence:

- Browser `postJson` threw an HTTP error without `outcomeUnknown`, and
  `submitDurable` deleted the original journal row.
- Native `Transport.Send` marked HTTP 413 as `Definite`; `SignedSession.Dispatch`
  then called `Forget` on the original durable operation.

The parent reproduced the browser failure through the production signing,
HTTP and journal owners with an injected HTTP response. The receipt is
`../stage2-presentation-limits-20261103/logs/parent-recovery-baseline01/result.json`:
Node child exit 1, both streams EOF, one send and zero retained operations.
This is a client-contract baseline; no server commit was performed by that test.

The applied follow-up maps `result_too_large` to HTTP 503 and marks browser
server errors as outcome-unknown. Native Dispatch already retains HTTP 503.
The correction preserves the original signed request as recovery identity,
without manufacturing a committed or pending receipt. HTTP renderer, durable
browser/native retention and exact-request resolution checks remain necessary.
The earlier failing baseline remains literal; changing the server status must
be verified with a newly labelled fixture and the actual renderer assertion.

## Remaining resource policies are not encoding facts

The known subquota removal does not eliminate all hardcoded resource policies:

- `QUOD_TRANSPORT_MAX_FRAME_BYTES` is 1 MiB; link parsing and the client-goal
  endpoint enforce it. The transport's 32-bit length field is a distinct actual
  representation constraint. A 1 MiB cap does not follow from that field.
- `QUOD_MAX_TOPLEVEL_GOAL_BYTES` remains 128 KiB for signed ingress and actor
  text, independently of the removed nested invocation quota.
- The 900 KiB foreign-page allowance and 64-validator assumption contribute to
  derived block, canonical transaction, DTX and scope capacities. Simply raising
  or deleting one macro is not a coherent policy-ownership correction.
- Structural term depth 64 is shared by codecs/parsers and mirrored in browser
  and native adapters. Signed token/digit quotas are additional ingress policy.
  They are not limits imposed by Prolog's domain model.

Current `quod_material_admission` selects founding, plan and proof resources
from pinned committed Prolog state. It does not currently select general raw
transport or signed-parser ingress allocations. The existing `quod_runtime`
resource-selection/dependency/install path provides the lifecycle precedent;
root effect custody already uses it. Proof `heap_bytes` and `answer_bytes`
must not be described as admission policies for every network/parser process.

Remaining owner and bootstrap/recovery semantics must be settled in the actual
shared path before claiming all hardcoded limitations removed. No new numeric
cap, alternative stream, catalogue exception or deployment is proposed here.

The bootstrap dependency is concrete: `quod_app:start/2` starts `quod_sup`
before `maybe_join/1` and `maybe_start_ns/1`; `quod_quic` is the supervisor's
first child. Transport is therefore needed before committed root policy is
available on a joining node. Unlike effect custody, raw transport cannot simply
wait for root recovery if that recovery itself needs transport. A policy refactor
must account for initial join and recovery explicitly, including which existing
authority supplies admission before root is available. This review has not
selected a bootstrap fallback or invented an allowance.

Subsequent user clarification: a new node connects to its contact node and
syncs root, with no additional startup mechanism requested. The parent withdrew
its unnecessary bootstrap-policy choice. Alongside the standing instruction to
remove hardcoded ceilings, this directs the remaining work to preserve ordinary
connect-and-sync behavior through existing owners. The previously reported
bootstrap question is therefore no longer a user-decision blocker. The 14-second
measurements concern large-display renewal, not node startup or root sync.

The shared transport macro also reaches ledger decoding, catchup, feed,
consensus proposals and foreign-history storage. `MAX_VALIDATORS` is not just
padding arithmetic: committee admission, quorum signature-list validation,
agent identity certificates and retained DTX/foreign-view validation use it.
These are live callers. Removing the arbitrary ceilings must preserve their
membership, signature and historical-verification obligations rather than
treating the header deletion as a complete implementation.

## Evidence boundaries

The running signed01 campaign uses its pinned owner03 inputs, before the HTTP
recovery correction. Any success from that campaign belongs to that source.
The final evidence must separately cover the recovery correction and identify
the source impact of every later edit. The reviewer's claimed memory probe is
excluded from runtime evidence as recorded in the previous correction.

Subsequent receipt checks: signed01 ended with server exit 0, client exit 1
and all four streams at EOF. The large-display and picking assertions passed;
the client then raised TaskCanceledException at the renewal receipt wait. This
is a failed campaign, not full signed acceptance. No deadline extension follows.

The parent checked codecs01 and proof01 receipts (owner04, child exits 0,
both streams EOF) and their logs: 79 and 225 tests passed respectively.
browser01 also exits 0. The new browser test exercises production HTTP/journal
handling with injected 503 and exact original-request resolution. Native02's
restore/build/recovery/finite steps each exit 0 with both streams EOF; its
production Dispatch/Resolve checks additionally reopen the durable local store
and verify original bytes/signature, one execute send and one outcome lookup.
These injected-response tests prove client recovery behavior, not a real server
commit. Native01's disposed-transport fixture failure remains separately saved.

One parent documentation edit attempt had incorrect patch context and changed
nothing; the precise-context edit succeeded. It was not a production/test rerun.

`inspection08` exits 0 with both streams EOF. Its unchanged full-catalogue
assertions cover all 376 sorted entries, each exact bound lookup and an absent
predicate; the test log reports 2.436 seconds. This checks the inspection query,
not full signed renewal performance. Earlier inspection timeouts and signed02/03
opening failures remain separate evidence. The query still computes the sorted
catalogue internally: smaller returned results must not be described as zero
catalogue computation or a retained projection cache.

`signed04` remains failed (server 0, client 1, four EOF). Its client log records
renewal attempt intervals of 19,500 ms and 10,474 ms; the second wait ends with
TaskCanceledException. The timing is printed from `finally`, so the second
interval is not a completed renewal. The three-renewal check did not complete
within its original 30-second measurement window. The focused inspection
success does not supersede this signed failure.

The parent checked `denial-baseline01` (server 0/client 1/four EOF) and
`denial-fixed01` (both children 0/four EOF). The fixed signed checks cover
revoked selected contents, direct interior reads and authorized ordinary empty
contents. The ontology class now selects an ordinary recipe which requires
source inspection before invoking the existing contents projection; interior
projection uses class selection too. There is no client type dispatch or second
composition algorithm. `projection01` passes the affected shared recursive and
physical-agreement test (owner10, exit 0/both EOF). `inspection09` passes all
catalogue/ordinal assertions plus exact membership checks (exit 0/both EOF).

The renewal observer counts `quod_erlog_db_mvcc:get_interpreted_functors/1`, not
only the Prolog query name. It therefore includes scans made by both membership
and ordinal queries. The qualified Erlog `current_predicate/1` implementation
still enumerates the interpreted functors for a ground indicator; narrower
returned results must not be labelled an indexed lookup.

`lifecycle-signed01` is a separate diagnostic with a changed observation
condition: it places each renewal in its own 30-second window. The parent did
not accept this as satisfying the user's unchanged-deadline requirement and
instructed preservation of the original aggregate-three-renewal obligation.
The diagnostic exits 0/0 with four EOF and reaches update, cycles, withdrawal,
stale-selection refusal, restored permission, disconnect/reconnect and unchanged
A location. Its three completed renewal observations are 13,483/13,404/13,509 ms,
each with 857 actual catalogue calls and zero calls to the listed history,
physical-install and file-write/sync functions. Those facts are diagnostic
evidence only; they do not turn the original failed campaign green.

Further source review found that the ontology recipe's `predicates` guard and
membership's `predicates(Indicator)` enumeration use different admission shapes.
An ACL may permit the former and deny the latter. The class guard must cover
the actual enumeration shape; the all-source-denial success above does not
prove this selective-denial case. A separate real signed check is in progress.

That case is now independently verified: `selective-baseline01` fails with
server 0/client 1/four EOF, and `selective-fixed01` passes with both children 0
and four EOF. The recipe guard now asks `predicates(_)`, matching membership
enumeration. The signed fixture keeps the distinct `predicates` query allowed
and nonempty while requiring selected contents and interior reads to refuse.
Authorized ordinary empty contents still succeed.

## Isolated interpreter candidate

The signed CPU profile separates the renewal bottleneck from node startup.
`profile-signed01` records 14,689,169 microseconds elapsed and 14,786 ms VM CPU.
Catalogue scanning accounts for about 396 ms and follower-body preparation
about 54 ms in that profile; neither explains the full delay. Later profiles
locate repeated deep resolution of list tails in interpreted-goal dispatch.
Broad recursive tracing itself exceeded its observation window and is retained
as a failed diagnostic, not equivalent to uninstrumented runtime evidence.

The parent reviewed `proposals/erlog-dispatch.patch`: interpreted calls use
shallow resolution; native calls still receive deeply resolved arguments.
Failure boundaries retain the original immutable bindings and resolve them
only when producing the failure diagnostic. This preserves the original-call
meaning rather than reporting later bindings. The proposed production delta
is +11/-10, in the existing interpreter owner.

`dispatch-baseline01` exits 1 with both EOF: doubling the traversal input
changes deep-resolution calls from 17,548 to 67,852. `dispatch-candidate01`
fails before tests because its Erlog test-source path was absent. The separately
labelled `dispatch-candidate02` exits 0 with both EOF and passes all 117 focused
tests, including the traversal counts 262 and 518, failure snapshots, native
arguments, aliasing, cut, backtracking and choicepoint contracts.

This candidate remains isolated and unpinned. Its test results do not establish
that the worktree's pinned dependency has been updated or that the original
signed acceptance has passed. The proposal manifest's earlier execution state
must not be confused with the later candidate test receipts.

## Admission codec follow-up

The isolated interpreter candidate did not make the original signed renewal
campaign pass (`dispatch-signed01`); it remains separate from the requested
ceiling refactor. No pinned dependency correction is inferred from its focused
tests.

Parent independently read `inputs/admission-codec01.json` and its complete
test summary: nine checks pass, true exit 0, stdout and stderr EOF. These cover
a complete link payload above 1 MiB, signed goal above 128 KiB with exact
signature/bytes, canonical and wire terms nested beyond 64, larger token and
integer populations, long opaque symbols without atom creation, durable goal
and result encoding, and finite versus unlimited codec allowances. This is
codec evidence, not acceptance through HTTP, peer or durable admission owners.
The receipt lists seven Erlang source hashes but omits included header hashes;
the header inputs must be accounted for separately in the exact source freeze.

Current source removes the scope invocation's size comparison while retaining
the invocation ID shape, nonempty exact identity chain, selection validation,
duplicate ID refusal and existing authorization path. HTTP delivery overflow
continues to map to 503; original signed-operation recovery remains distinct
from pre-admission refusal.

Two surviving values must not be described as intrinsic encoding widths:
`DIRECTORY_MAX_NAMESPACE_BYTES = 255` (the signed request's namespace length
field is 16 bits) and the 16384 newly materialized atom allowance (a configured
VM allocation budget, not the VM atom table's actual capacity). The directory
validator only checks nonempty binary plus the former quota. The implementation
session has these concrete source observations; this review does not claim
either has been removed.

Native JSON parsing has its own library defaults, but that alone does not prove
a reachable term-depth restriction: ordinary result bindings and agent
references are serialized as Prolog text or base64 strings inside JSON. Any
claim of a remaining structured JSON depth blocker needs its actual caller and
payload, rather than an assumed correspondence with Prolog nesting.

## Carrier correction approval rejection

`inputs/carrier-edit-rejection01.json` records a new rejection before execution
of the combined carrier/custody edit and compile command. Its stated reason is:

> The broad scripted production edit removes multiple material, custody,
> transaction, journal, history, and carrier ceilings beyond the specifically
> authorized 128/512 KiB fixes, risking weakened protocol and resource
> protections without narrow owner-by-owner authorization.

This is the reviewer's authorization assessment, not a retraction of Yan's
recorded broader instruction to remove hardcoded limitations. It does not
retroactively make the earlier applied corrections unapplied. The rejected
command did not run; no retry or indirect execution is authorized by this
review note. The implementation session is preserving the applied tree and
preparing the exact blocked remainder for review.

Independent current-tree compilation `admission-current01` succeeded with
true exit 0, both streams EOF, 18.06474234 seconds. Its receipt includes source
and header hashes. This establishes compilation, not coherent end-to-end
admission or retirement of remaining carrier checks. The earlier
`material-baseline02` exits 1 with both EOF: large-plan admission, finite-policy
attribution, large transaction material and committee size assertions fail;
the reservation case times out during repeated fixture construction, before
establishing a reservation-owner failure.

## Applied codec and router verification

`admission-browser01` passes all four affected test files with true exit 0 and
both EOF. `admission-native01` records restore, build and six codec checks, each
with true exit 0 and both EOF. Native checks retain deep term structure, long
symbol identity, exact large signed bytes, large actor/goal text and trailing
projection refusal. They are adapter checks, not a new complete signed scene
acceptance.

`admission-focused01` has 140 passes and two failures, true exit 1 and both EOF.
One fresh VM cannot create `/.erlang.cookie`; the other fixture incorrectly
expects a successful live cursor to release its route. `admission-focused02`
reruns only those two affected checks after fixture corrections: explicit peer
cookie arguments, and retaining the cursor route until the existing stop
command receives its terminal reply. Both pass with true exit 0 and both EOF.
Parent read the corrected stop/lease assertions. This is not a claim that the
first failed run passed, or that production needed to discard live cursors.

## Unapplied carrier proposal review

Parent read all four diffs in `proposals-carrier01/carrier-custody.patch` and
verified each current production file still matches its manifest's saved
before hash; both before/after artifact hashes also match. The proposal is
+27/-58, uncompiled and unexecuted. No application is implied by this review.

Scope messages would enforce the actual 32-bit complete-frame capacity while
removing duplicate material subquotas. Replay decoding would stop imposing
the unrelated plan byte allowance on a nested goal. The phase index retains
history validation and the fixed phase model. The signing journal retains
canonical decoding, CRC, signatures, sequence checks and its existing 32-bit
frame representation. No specific defect was found in this subset by source
review; runtime behavior remains unverified.

This subset does not retire the 900 KiB history page policy, derived durable
admission and queue budgets, 64-member assumption, namespace/atom allocation
budgets or dependency diagnostic quotas. It cannot be presented as the whole
remaining refactor.

The subsequent applied link framing change temporarily moved framing across
the existing mailbox seam. Although `admission-link01` passes 25 link checks,
router/feed/ask/DTX/Simplex fixtures consume `{send_ordered, Payload}` as the
original envelope. The earlier router checks predate this change. Parent
reported this concrete fixture-contract regression: checking `iolist_size`
before conversion/enqueueing does not require changing where framing occurs.
The implementation session must reconcile this before attributing earlier
router verification to the final link source.

Parent reproduced the mailbox regression as `parent-link-contract01` using
the existing router large-result test and the current link owner. True exit 1,
both streams EOF: `sent_request/1` receives `protocol_error,bad_etf` because the
test link's established payload seam now contains a frame header. The runner
snapshots its source and header inputs before compilation into its isolated
build directory, records hashes and preserves both complete output streams.
No blocked proposal or production edit was applied by the parent test.

The implementation subsequently restored the raw-payload mailbox contract.
`admission-link02` records 50 link/router passes with true exit 0 and both EOF.
This supersedes the framing source implicated in `parent-link-contract01`,
without deleting that failed receipt.

## Explicit carrier02 authorization

Parent interactive prompt cell202 completed with the desktop choice
`carrier_authorization = authorize`. The exact action was application and
affected transport/recovery verification of the four-owner
`proposals-carrier02/carrier-custody.patch`; no commit, deployment, cleanup or
execution replay. `inputs/carrier02-user-authorization.json` records the scope,
wording and response. Revision02 additionally removes the journal reader's
newly unreachable frame-too-big branch; its production delta is +27/-61.

The implementation session received the new authority. The earlier rejection
and unapplied proposal labels remain historical evidence, not a reason to ask
again for this approved action. Approval itself is not evidence of application
or passing tests; those need their own subsequent receipts.

## Remaining namespace storage dependency

Source tracing finds a separate reason not to describe namespace255 as an
intrinsic protocol width. `quod_ledger_store:ns_dir/2` encodes the raw namespace
as one base64url filesystem component; the main ledger and signing journal
share this owner. Simplex passes the raw namespace. Foreign caches instead
hash the anchored identity before using this directory helper.

Read-only `getconf NAME_MAX /home/yan/src/quod_worktrees/pearl-stone` returned
255 with exit 0. Unpadded base64url expands 191 bytes to 255 characters and
192 bytes to 256. Thus, on a filesystem with that component capacity, the
current storage representation can fail below the compiled namespace255
quota. No actual namespace store was created by this observation, and the
configured production data directory's filesystem was not tested. This is a
source-backed storage-format dependency, not a justification for another
smaller quota or an authorized data migration.

The signed request's 16-bit namespace-length field and the link header's
16-bit complete-channel-length field are also different encoding capacities:
feed/catchup channels contain ETF framing around the namespace. Their actual
enclosing widths must not be conflated with the retired resource policies.

## Applied carrier02 verification

`carrier02-application` records the approved patch application with true exit
0, both EOF and verified before/after hashes. `carrier-owner01` compiles all
production Erlang modules with true exit 0 and both EOF. `carrier-current01`
has 104 passes and one missing legacy journal fixture (`enoent`); the isolated
`carrier-fixture02` check passes after supplying that fixture. Recovery checks
in `carrier-recovery01` pass all 68 tests, including the large journal path.

`carrier-signed01` renders the full catalogue, long identities and native
picking, then fails before renewal: the measurement socket closes because
`quod_physics_tests:observe_live_geometry_work` is unavailable. Parent verified
the `undef` in a bounded extraction from the private server log and the client
null JSON at LimitsChecks line37. Server 0/client 1/all four EOF. This is not
a renewal timeout. `carrier-signed02` supplies the helper and reaches the
original aggregate observation: two renewals complete, the third is cancelled;
server 0/client 1/all four EOF. The original performance obligation stays open.

Retiring unused production quota definitions exposes eight obsolete quota
expectations in `carrier-retirement01`: 215 pass/eight fail. The isolated
`carrier-retirement02` reruns those eight after contract updates and passes.
Parent inspected the replacement assertions: large values round-trip exactly;
malformed certificates still fail by shape, altered certificate statements fail
signature verification, malformed runtime answers and compressed payloads
remain refused, finite authored proof allowances retain their explicit error,
and complete transcript material remains equal after sealing/decoding. These
updates remove old size refusals rather than weakening those valid obligations.
