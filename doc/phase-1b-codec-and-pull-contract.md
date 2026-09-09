# Phase 1B — shared artifact and page-handoff contract

**Status: all three cut contracts approved; Cut 1 reviewed and committed as
`e4ad3e1`, version 0.7.153 (`43bd48c`). Cut 2 reviewed and committed as
`8ca87e8`, with the separate 0.7.154 bump `dd98f53`. Cut 3 is independently
reviewed and committed as `ecb7861`, with separate 0.7.155 bump `49f3759`.
All three cuts are deployed; matched N=4 hardware measurement is complete,
with its evidence independently reviewed and approved. Absolute latency gates remain
unmet.**
Baseline `d48cd89` / 0.7.152. Claude verified and approved the completed
owner-decode, shared-artifact and final-confirmation contracts. His three
small clarifications are folded in below: exact binding re-check at decode
completion, error-response successor-credit coverage, and nullable `from`
typing. Cut 3 was implemented under Yan's subsequent authorization. Every cut
requires fresh sequential gates and review before commit; cut 2 is consensus-facing. Broader
probe-response reuse and cryptographic redesign remain closed.

The accepted 0.7.152 baseline remains in
[its hardware report](phase-1a-hardware-results.md). The new
[0.7.155 measurements](phase-1b-hardware-results.md) retain all 400 requests,
the serial outlier and the remaining missed gates; functional review alone
was not used to claim these measured savings.

## 1. Page interpretation: one retained pull, two local handoff steps

The existing foreign-log owner retains each `#pull{}` from admission through
page decoding. The existing immediate puller—verification worker or one of
its existing linked probe children—does the decode. The owner does not spawn
a decoder. `#page_binding{}` still owns the exact link/lease and spendable
credit; the pull row owns its operation and pending successor grant.

### 1.1 Row and correlation

The old `submitted` field is deleted. One explicit `turn` state in that same
row owns the lifecycle:

- `queued`: no grant spent; original call reply still pending;
- `sent(Link, BindingRef, Grant)`: one request sent; original reply pending;
- `decoding(Link, BindingRef, Grant, NextGrant)`: raw page delivered; successor
  grant held and not spendable; original call reply already consumed.

There is no terminal row: existing completion removes it. Binding retirement
continues to use the existing binding's `retiring` field, not a second map.
Keep `request_ref`, range, original absolute deadline, timer and puller monitor
in the row. Retain the immediate puller PID explicitly because `from` becomes
`none` after the one raw-page reply. The monitor covers decoding as well as
waiting; raw delivery must not demonitor or cancel the existing page deadline.
Declare the field as `from :: none | gen_server:from()` in the record, and
make the cleanup helper branch on that union, so Dialyzer checks the consumed
reply state rather than leaving it as a test-only convention.

The local page key is `(OwnerPid, ReqId, BindingRef, LinkPid, Grant)`. OwnerPid
is the foreign-log incarnation captured by the existing requesting worker;
do not re-resolve registration for completion. The actual completion-call
`From` PID must equal the retained puller PID. The owner retrieves NextGrant
from its row; the worker cannot choose a grant or install one.
At the **decoded-completion handler**, before cleanup or grant installation,
re-read the current binding and require `ref = BindingRef`, `link = LinkPid`,
`active = ReqId`, `retiring = false` and `credit = none`, together with the
matching decoding pull/key, consumed `from = none`, actual caller PID and
unexpired deadline. Key's OwnerPid must be `self()`. Pin this match/assertion
in code; a saved key alone is insufficient. A mismatch must not install credit
or alter an unrelated replacement binding. This is a check of the existing
owner's serialized binding state, not a new liveness probe or reconnect path.

### 1.2 Handoff and public result

Keep `fetch_page` as the single semantic facade. Its production `pull_page`
call receives either the existing terminal error or an internal
`decode_page(Key, Blobs, CapturedHeight, EffectiveDeadline, TestGate)` reply.
EffectiveDeadline is the owner's original budget (possibly shortened by the
enclosing follow); TestGate is inert in production. That internal reply is **not**
a fetched/verified page result for any caller outside this facade.

The same worker calls the one `quod_catchup:decode_entries(Blobs, wrapped)`
boundary, retaining the decoded page locally. It then completes the local
handoff with a call to the **same owner PID**, carrying Key and the closed
verdict `decoded | malformed`. This completion call replies immediately from
the owner transition; it is not another queued verification job. It shares
the original absolute page deadline, including pre/post-call checks, and
cannot renew the budget. Both exact-PID calls use the time remaining on that
same deadline; completion cannot wait indefinitely after its row timer was
cancelled. There is no network ACK, additional timer, retry or new worker.
The existing borrowed-local-snapshot fetcher already supplies decoded entries
and remains unchanged; it does not spend a remote grant.

Only `decoded` accepted by the owner before expiry permits the facade to
return `{ok, Entries, CapturedHeight}` to its verifier. On failure, discard the
local decoded value and return the existing error vocabulary. An expired or
retired key produces `{error, retry}`, never ordinary Prolog false and never
automatic re-submission. Malformed decoding takes the existing conservative
cancel path; an actual worker crash is handled by its retained monitor.

The decode-completion step finishes **before** subsequent page requests or
semantic forward verification. Credit must not wait for full history
verification, persistence or final tip confirmation: that would strand the
same verifier's next page behind its own active request. Conversely, successful
page decoding still grants no history authority. Forward verification, durable
append, phase-index commit and checkpoint publication keep their own order.

### 1.3 Complete transition table

All rows below run at the existing foreign-log owner. `cleanup` means remove
the pull, cancel its existing timer, flush its immediate-puller monitor, clear
the binding's exact active/queued reference, and consume `from` at most once.

| State/event | Transition and credit | What the puller may receive/use |
|---|---|---|
| New valid request | monitor the puller, capture the existing deadline, enqueue one row | no result yet |
| Queued + exact link credit | consume Grant, mark sent, send once through existing `request_page` | no result yet |
| Queued + expiry/caller death/cancel | cleanup; no grant was spent; other runnable rows proceed | existing error if original reply still live |
| Sent + matched successful wire page before deadline | mark decoding; reserve NextGrant; deliver raw blobs once; set `from = none`; keep active row, timer and monitor | raw internal handoff only |
| Sent + matched `not_ready`/`server_error` | cleanup, install received NextGrant, drive next unsent row | existing terminal error, no decode step |
| Decoding + exact retained-puller `decoded` on a still-active turn, before deadline | re-check the current exact binding as specified in §1.1, then cleanup, install reserved NextGrant once, drive next unsent row, acknowledge local completion | facade may now return its locally decoded page |
| Decoding + `malformed` | cleanup, discard reserved NextGrant, close the exact submitted link, mark binding retiring with credit none | `{error, retry}`; decoded data discarded |
| Sent **or decoding** + puller DOWN, deadline, actual request cancellation | same `cancel_pull_owned` classification: cleanup, discard any reserved successor, close the exact old link, mark retiring | error to an outstanding original reply; a later completion gets retry; no page use |
| Sent or decoding + exact link DOWN/transport-generation loss | existing `retire_page_binding`; cleanup the active pull, release exact lease, clear link/credit | existing link-down error if original reply remains; later completion gets retry |
| Retiring binding + old link DOWN | existing unsent-row reconstruction, preserving their IDs/ranges/deadlines; never reconstruct the cancelled sent row | only unsent rows can subsequently run |
| Foreign owner dies/is replaced | existing producer/link lifetime cleanup; both local calls are exact-PID monitored calls | typed unavailability/retry; never finish against the replacement owner |
| Wrong PID/key, duplicate or late local verdict | refuse/ignore without altering another row/link; do not install supplied credit | no page publication |
| Duplicate/stale/invalid wire frame | keep existing link grammar and generation checks; no second raw delivery | no page publication |
| Upstream verification caller detaches but shared work remains | detach only that caller; the immediate puller and its page row stay live | remaining shared callers unaffected |

**Worker death during decode is resolved, not parked:** the retained tagged
`catchup_page_owner_down` monitor invokes the same sent-operation cancellation
as before, including exact-link close. A completed frame does not justify
reusing content whose decode verdict was lost. The binding cannot remain
`credit = none, retiring = false` with no possible verdict. No timer is needed
to discover this death.

For verdict/death or verdict/expiry races, the owner's accepted transition is
decisive. If expiry/death retires first, a later verdict is inert. If valid
decode completion happens first, that page turn is complete; a later stale
DOWN cannot revoke its successor grant. Semantic publication still belongs to
the live verifier and its existing cancellation rules. Every completion checks
the absolute deadline even if the deadline message itself is queued.

One cleanup helper must handle `from = none`: never reply again to the consumed
raw-delivery alias. The completion call has its own immediate reply; it does
not reuse that alias or create retained terminal outcomes. No result cache.

**Tracing:** `quod.foreign.page_fetch` contains worker `page_wait`, `page_decode`
and `page_completion` spans, plus short `page_delivery` and
`page_completion_owner` spans at the owner. Existing probe children inherit
the requesting verifier's trace context; their collection/termination policy
is unchanged. Owner work overlaps the corresponding wait span: use interval
unions, not sums of nested or overlapping durations. Context stays transient
in the existing pull row; no page contents or correlation keys become labels.

## 2. Shared canonical artifact contract

This cut is **consensus-facing by construction**. Local Simplex persistence,
catch-up installation and foreign-history persistence all use
`quod_ledger_store:append/2`; there is no foreign-only append carve-out.
The concrete artifact definition and shared boundary below are approved as a
contract. Their implementation still requires the same review-before-commit
discipline as any consensus-facing change.

### 2.1 One immutable representation, owned by the existing ledger codec

Make a committed entry a private `quod_ledger:entry_artifact()` containing:

    canonical_entry(EnvelopeBytes, EntryView, BlockViewOrNone)

EnvelopeBytes is the exact existing canonical `quod_entry` envelope, not a new
format. EntryView is the existing `#entry{}` interpretation; BlockViewOrNone
retains the already-decoded parent/header/payload view, avoiding a later decode
just to recover the parent. A skip has no block. An implicit certificate's
child view is derived from, and bound to, its exact carried child bytes too.
The wrapper is process-local data; it is never a new wire or disk term.

The invariant is **one envelope and the interpretations established from it**,
not a `verified` flag. Do not put committee-currentness, a projection, an owner
PID, admission, a capability nonce or cached verdict in this object. Those
facts have different lifetimes and remain in their existing owners. Binary
sharing avoids copying payload bodies into another cache; the views already
exist today. This representation is not a second ledger.

### 2.2 Producer/consumer API contract

The following replaces the committed-entry API in place; it does not add a
parallel fast path for a second accepted input shape.

| Existing owner/API | New internal contract |
|---|---|
| `quod_ledger:entry(Block, Cert)` | validate the supplied block view against its bytes, validate any supplied implicit-child view against its bytes, construct the existing canonical envelope, and return one artifact |
| `new_entry/4`, `noop_entry/2` | use that same checked local construction; preserve current genesis/skip grammar and error behavior |
| `decode_entry(Bytes, SymbolMode)` | the existing single decoder validates canonical framing/grammar and nested signed transactions, derives both views in the selected mode, and retains those exact input bytes in the artifact |
| `from_entry_view(EntryView)` | checked import at the existing native prepared-genesis boundary; validate all supplied view/byte fields, including implicit child if present, using the same codec logic, then mint the same artifact; no trusted-record option |
| `entry_view(Artifact)` | expose the already-bound `#entry{}` interpretation for read-only pattern matching by reducers/consumers; no encode/decode |
| `block_from_entry(Artifact)` | return the already-bound block view or existing skip/error result; no parent-recovery decode or view re-encode |
| `encode_entry(Artifact)` | return the exact envelope bytes; no encoding or signature verification |
| `quod_ledger_store:append(Store, Artifacts)` | sole append API, now artifact-only; contiguous indices and frame bytes come from those same objects, not separately supplied metadata |
| `decode_entries`, `page_stats`, serving/feed/sidecars | carry the artifacts, count their exact envelope byte sizes or forward their bytes through the existing envelope codecs |

There is no `append_raw`, `append_prepared`, alternate naked-record branch or
`skip_verify` option. The artifact record/tuple definition and minting helpers
remain private to `quod_ledger`; other modules use the named constructors and
accessors. Existing raw `#entry{}` consumer patterns become access through
`entry_view`, not another constructor. A caller wanting a different entry must
use checked construction; it cannot attach a changed view to previous bytes.

Keep proposal `#block{}`, staged/signed `#transaction{}`, transaction codecs
and signing-journal APIs unchanged in this cut. In particular, do not strip
`verify_submission` out of the shared transaction encoder globally: its
constructor/ingress validation remains necessary. The saving comes from entry
consumers no longer invoking it again merely to measure, frame or forward an
entry. Local entry construction still checks arbitrary supplied block records.

`entry/2` and `from_entry_view/1` are symbol-mode-neutral: validate supplied
interpretations against their bytes without implicitly materializing foreign
symbols. Only the explicitly mode-selected decoder changes interpretation.
Mode conversion is not a flag update on the artifact: where a legitimately
different interpretation is required, use the existing decoder with the same
bytes and explicit symbol mode. Foreign consumers remain wrapped. Tests compare
canonical bytes across modes, not atom-bearing versus wrapped term equality.

**Actual trust boundary:** an opaque Erlang type cannot prove provenance to
arbitrary code already running inside the VM. Every canonical-entry byte
ingress accepts the existing byte grammar and calls the checked decoder;
§2.5's existing native prepared-genesis boundary uses the checked view import.
Neither accepts a
deserialized artifact-shaped term or `{Bytes, ClaimedView}`. The production
constructor/caller inventory must prove that all internal artifacts originate
there or at the checked local constructors. Pin private minting and all ingress
sites with the existing AST-audit technique. This is a checked dataflow
contract, not a cryptographic property of the tuple tag. It does not authorize
untrusted callers to submit arbitrary terms to a raw storage API.

### 2.3 Who validates what, and in which order

Representation integrity does not establish finality, currentness or authority
to append. Keep these independent responsibilities at their present owners:

| Producer path | Construction and acceptance order |
|---|---|
| Local genesis | existing prepared-genesis/anchor checks → checked local entry constructor → ordinary store append; no new genesis exception |
| Live local commit or complaint skip | existing proposal validation and finality/complaint guards → checked entry/skip constructor → ordinary append → existing feed, history/application and completion ordering |
| Foreign page | bounded raw blobs → immediate worker's one wrapped entry decoder → §1 page handoff accepted → unchanged contiguous/anchored forward verifier → prepared page → ordinary append → phase commit → checkpoint → owner publication |
| Local catch-up/feed gap | same entry decoder and existing forward verifier → existing Simplex sink checks its exact starting snapshot and contiguous next slot → ordinary append → existing replay/application |
| Disk recovery/read | current framing/CRC/index checks → same entry decoder → existing recovery/history validation where required; no “trusted disk” bypass |

The forward verifier accepts artifacts and obtains its entry/block views from
them. It still validates the genesis anchor, certified slot-era committee,
ancestry, implicit finality, target/admission, author sequence, OCC and DTX
semantics at their existing seams. The live consensus path keeps its existing
accepted-proposal/verified-history distinction: do not add the foreign replay
verifier to each local append as compensation for making serialization cheap.
Neither the codec nor the store is a new authenticator or consensus owner.

`prepare_verified_page` retains the **same ordered artifacts** accepted by the
forward fold alongside its derived projection and phase delta. Remove any
second independently assembled entry list. Counts/reservation sizes derive
from those artifacts; `persist_verified_page` cannot substitute another list
after verifying one page. The same starting-snapshot/stale-window refusal in
Simplex catch-up remains: never trim a verified window while keeping the old
projection if live consensus advanced during the fetch.

Store append retains the contiguous-index check, 12-byte frame/CRC format,
sparse checkpoint offsets and one batch `datasync`. It frames EnvelopeBytes
directly. It does not newly accept naked blobs or caller-selected indices.
Post-append phase/checkpoint failures keep the current fail-loud/recovery rule:
never restore the pre-append handle and splice over newly durable bytes.

### 2.4 Exact migration and deletion inventory

These are the current production sites on the baseline, not examples:

| Boundary | Sites that must migrate together in the shared artifact cut |
|---|---|
| Append | Simplex `append_genesis`, `persist_entry` (commit and skip), `apply_catchup_window`; foreign-log `persist_verified_page` |
| Encode/extract bytes | ledger-store append; catch-up `page_stats`, `cap_bytes`, serving reader; feed `encode/2`; DTX endpoint entry sidecar encoding |
| Decode input | ledger-store read and cold scan; catch-up `decode_entry_blobs`; feed signal decoding; DTX endpoint sidecar decoding |
| Read semantic views | forward/history validation, certified-reference construction/checking, application/runtime/Explorer and other existing entry consumers; views come from the artifact accessor |

Before implementation, mechanically refresh the exact MFA inventory from
source, including indirect wrappers. Test that no production module outside
the codec constructs or mutates an artifact and no old raw-record append
branch survives. No compatibility adapter, foreign-only exception or fake
signature in fixtures. Negative record/view tests use the checked constructor
or actual ingress, not an invented claim that Erlang private types prevent
hostile in-VM tuple construction.

Delete the repeated entry decode/re-encode in `block_from_entry_view`, repeated
entry encoding for size accounting and storage/transport, and the superseded
raw-entry API branches and comments. Preserve every actual signature/semantic
check at its acceptance boundary. The constructor's binding validation is not
deleted just because the later accessor is cheap.

### 2.5 Persistence audit: preserve the prepared-genesis boundary explicitly

The source audit found **one actual native-entry persistence boundary**, not
just a hypothetical risk. `quod_ontology:prepare_create` places Entry inside
`Config.prepared_genesis_entry`; `prepared_bytes/1` serializes that config in
`quod_prepared_lifecycle`. Those bytes are hashed by `prepared_effect` and
retained by the effect journal. Replacing that native entry with an artifact
would change both private durable bytes and the certified effect's prepared
hash. An unadapted recovery is worse: the pre-Cut-2
`quod_simplex:genesis_entry` recognized `#entry{}` and otherwise fell into
fresh genesis generation. The Cut-2 implementation replaces that dispatch
with the presence-and-validation rule below.

Pin the boundary for **all** new preparation and recovery, not a compatibility
branch recognizing two stored formats:

1. `prepare_genesis` constructs the checked artifact and derives its anchor
   as usual. Before `quod_ontology` freezes the prepared config, project
   `entry_view(Artifact)` into the existing `prepared_genesis_entry` field.
   The serialized `#entry{}`, its `#transaction{}` and certificate shapes,
   `prepared_bytes`, prepared hash and effect identity stay byte-for-byte
   unchanged for the same founding inputs and already-chosen incarnation.
   Never serialize the artifact tuple itself.
2. At activation, `genesis_entry` branches on **presence** of the prepared
   field. A present value is checked/imported through the ledger codec's
   `from_entry_view`; retain the existing `valid_prepared_genesis`, identity,
   author and anchor checks. Bad shape, bad byte/view binding or a wrong anchor
   returns the existing typed genesis failure. Only an **absent** prepared
   field permits the ordinary fresh-founder branch. Do not regenerate an
   incarnation because import failed or a representation did not match.
3. Append only the resulting transient artifact through the one `append/2`.
   This import uses the same codec validation/private mint as local creation
   and byte decoding. It is not a second decoder, authenticator, journal,
   stored format or permissive record-to-append bypass.

Other audited stores: foreign checkpoints carry compact semantic projections;
DTX phase/outcome history carries controls and certified refs; signing-journal
support rows carry canonical block bytes and transaction/Begin rows their
existing envelopes; ledger sessions carry index metadata. None needs the
artifact serialized. Certified references do embed deterministic **certificate
record bytes** (`quod_dtx:certified_entry_ref`); keep `#cert{}` and implicit-proof
encoding unchanged too. Do not turn this cut into a certificate migration.

Thus no canonical envelope, signed bytes, block hash, certified-reference claim,
wire version, ledger frame **or prepared-effect format** changes. The tests
below must prove that boundary statement before commit; the source inventory
must be refreshed on the actual implementation, not assumed from this plan.

## 3. Final-confirmation collector contract

Generalize the existing `parallel_probes`/`collect_probes` completion rule,
not the verifier or transport. Initial `probe_pages` retains collect-all and
its maximum-height source selection. Only `current_committee_confirmed`
selects the threshold rule; `probe_confirmed_endpoint` and
`tip_response_at_least` remain unchanged.

Capture the committee and existing Needed threshold from the post-advance
verified projection once for that wave. Group candidate endpoints by their
committee peer key, retaining existing endpoint order and one endpoint-walk
worker per distinct peer. Duplicate hint rows/endpoints cannot create another
potential signer or response count. This is request-local collection state,
not an identity registry or a new quorum policy.

Maintain distinct confirmed peer keys and remaining unresolved peer keys:

- success when `count(confirmed) >= Needed`;
- failure when `count(confirmed) + count(unresolved) < Needed`;
- otherwise consume the next result/DOWN under the existing absolute deadline.

A response consumes only its exact pending PID/monitor/peer row, once. A peer
outside the captured committee counts neither as confirmed nor as a possible
future confirmation. A failed endpoint is not a failed peer while its existing
endpoint walk still has alternatives. These are authenticated peer responses,
not signed common-head votes. No response changes the captured committee.

On either terminal boolean, use existing `stop_current_probes`: terminate the
remaining linked probe children; their owner-held pull monitors reap queued,
sent and decoding pulls through §1. Cancellation of a spent page conservatively
closes its exact link; unsent work is reconstructed by the existing binding
logic. The semantic result need not wait for a network close acknowledgement,
but tests must observe eventual local monitor-driven reaping. No drain timer,
replacement collector, reuse of early H+1 replies or fresh budget.

## 4. Non-vacuous review and implementation gates

For the page cut, use barriers/messages in the existing real pull fixture:

1. Hold the decoder after raw delivery; assert its row, active key, monitor,
   original deadline and reserved-but-unspendable successor. Another identity
   on a different link completes while decoding remains held.
2. Kill the immediate puller at that barrier. Observe exact old-link closure,
   retiring cleanup and pull-row removal. An unsent sibling resumes on the
   replacement binding without retrying the killed request. Assert no orphan
   pull, monitor, grant or decoded-page publication.
3. Release a decoder and prove page-level completion allows the same verifier
   to request the next page and final confirmation; no self-deadlock.
4. Malformed page, expiry during decode, late valid verdict, duplicate verdict,
   wrong PID/key and link replacement each refuse publication and cannot lend
   credit to a replacement link. Test both orderings of verdict/DOWN and
   verdict/expiry; count replies so raw handoff is never mistaken for success.
5. Preserve the existing shared-caller-detach, borrowed-source death and
   zero-foreign-atom regressions. No production sleeps or new test-only owner.

Also exercise both `not_ready` and `server_error` through the real wire/owner
fixture with a second unsent row on the same binding. Each error returns
exactly once, never enters decoding, installs the received successor grant,
and sends that next row with the new grant without resetting the link or
retrying the failed row. This pins the error-response transition alongside
the new successful-page decoding state.
Use the existing real-owner
`page_credit_shares_pinned_binding_fifo_across_anchors_test` fixture,
parameterized by error reason; link-only credit tests do not cover this owner
transition. Assert the next request uses the same Link/Binding and received
NextGrant exactly once, then verify successful completion and row/lease drain.

For final confirmation, drive the actual collector and actual owner pulls:

6. N=4: hold one peer indefinitely at a message barrier; three valid distinct
   confirmations return success without releasing that barrier. Hold the
   enclosing current worker **after collector return but before
   `foreign_worker_done`**. While its request remains pending, assert the held
   child is killed and its in-flight owner pull is reaped. Otherwise whole-job
   `cancel_request_pulls` could conceal broken immediate-puller DOWN cleanup.
   Restore the
   old collect-all behavior in a non-vacuity check: it cannot finish there.
7. Two definitive failed peers make 3-of-4 impossible; return failure while
   remaining peers are held, then observe the same monitor cleanup.
8. Duplicate hints and duplicate result messages from one peer never count
   twice; two unique successful peers still cannot satisfy 3-of-4. Invalid
   era-bound history, malformed and noncommittee responses retain their
   existing refusal; empty tip replies do not carry a new era assertion.
9. Initial probing still waits for its delayed highest-height result and
   selects that height; final-confirmation early exit has not leaked into
   discovery. Compare all/threshold terminal booleans across response orders.

For the shared artifact cut:

10. Constructor rejection for mutated payload/index/timestamp/parent versus
    carried block bytes, and for an implicit child's changed view versus its
    carried bytes. Actual wire/disk ingress rejects invalid signatures,
    canonicality, trailing data and artifact-shaped terms.
11. Process-trace positives first establish that decoder/transaction-signature
    hooks work; then artifact size, encode, append and forwarding operations
    perform zero entry decode, transaction-signature verification or view
    re-encode. Valid local construction and foreign ingress still invoke the
    necessary checks. Test local commit, skip/genesis and foreign append.
12. Exact envelope bytes and CRC framing survive constructor → append → read
    → serve/sidecar, in both symbol modes. Foreign vocabulary never allocates
    atoms. Wrong anchor, era and certified reference still fail in the existing
    verifier even when their envelope is canonical.
13. Preserve same-batch sequence/OCC/DTX outcomes, committee transitions,
    implicit-certificate cases, backtracking and snapshot bounds. Reject a
    stale catch-up window without persisting its suffix or installing its
    detached projection. Pin exact constructor and ingress inventories.
14. Freeze one prepared creation with a fixed already-selected incarnation.
    Assert identical pre-cut/current prepared bytes, prepared hash, effect ID,
    entry envelope and genesis anchor; restart from its real retained effect
    journal and activate that exact creation. Assert no call to fresh genesis
    generation. A present malformed prepared field fails loudly, rather than
    selecting fresh founding. This tests the unchanged existing format, not a
    second legacy decoder or compatibility route.

All cuts require fresh sequential EUnit, ask CT, QUIC CT, xref, dialyzer and
diff-check. Keep the production-AST open-site guard and backtracking/MVCC
tests unchanged. Re-measure only after review/commit authority; no latency
saving is inferred from these functional tests. The next review is of the
authorized implementation and its test evidence, not another review of the
now-approved contract. Following Cut 1's clean implementation review, Yan
authorized its commit and continuation to Cut 2. Cut 2's implementation review
is now closed and it is committed. Yan subsequently authorized Cut 3's
implementation; its commit and deployment remain gated on review.

### Cut-1 implementation checkpoint — 2026-09-09

Only `quod_foreign_log` and its tests changed in source. Clean-build,
sequential gates passed: EUnit **1813/0**, ask CT **26/26**, QUIC CT **26/26**,
xref, Dialyzer and diff-check, all exit 0. The 14 added cases include exact
worker-only decoding, both server-error credit returns, held-worker death,
owner replacement, deadline ordering, same-worker pagination and real
confirmation-probe trace parentage. An isolated negative control restored the
removed owner decode and failed the call-trace assertion specifically on its
extra owner call; the normal tree passes that test.

Logs, fingerprints, the negative control and the review request are archived at
`/tmp/quod-phase1b-cut1-2w6QNe/`. Development fixture corrections and the
sandboxed peer-listener failure are disclosed in that handoff. Claude independently
reproduced all gates and source fingerprints and closed review with no findings.
Cut 1 was committed as `e4ad3e1`, with the separate 0.7.153 bump `43bd48c`.
No deployment or hardware saving is claimed. Cut 2 subsequently passed review
and was committed; Cut 3's current authorization is recorded in the status above.

### Cut-2 implementation checkpoint — 2026-09-09

The existing ledger codec now privately owns `entry_artifact()` with exact
envelope bytes, entry view and block view. Its single mint is reached only by
checked constructors/import or the existing byte decoder. All append/read,
page/feed/sidecar, certified-reference, reducer, runtime and Explorer consumers
carry that artifact; no raw entry branch remains at append or byte ingress.
The sole native import is the prepared-genesis descriptor, whose serialized
entry, preparation digest and fixed incarnation remain byte-identical.

This does not remove authentication work from the forward verifier.
`well_formed_block` still checks its original header ranges, payload bounds
and semantics; slot-era finality, signature and reference checks remain at
their existing owners. The removed work is reconstruction at the entry accessor
and repeated encoding/signature checks merely to count, frame, store or send.
Proposal/transaction encoders and the signing journal are unchanged.

Foreign entry sidecars explicitly select wrapped decoding. Simplex's local
reference arm ignores sidecars and uses its owner snapshot; only its foreign
reference arm consumes those hints through the existing wrapped history
verifier. The applied-certificate sidecar family cannot admit serialized
artifacts. Constructor checks also refuse slot-zero entries, wire-only
implicit certificates supplied as native views, and malformed child wire
values, so the artifact's view cannot change when its bytes are read again.

The new production AST inventory pins exact mint/constructor/import/ingress
and append sites and counts. The prior live-open inventory and MVCC/proof
engine tests remain unchanged. Frozen pre-cut codec vectors cover existing
envelopes and CRC frames; process tracing proves valid construction/ingress
does perform checks, while materialized and wrapped consumer operations do
none of that repeated work. An isolated negative codec restored the decode
inside `encode_entry`: all byte goldens still passed, while the consumer
regression failed on **46 repeated decodes and 38 signature checks**.

Final clean-build sequential gates passed: EUnit **1838/0**, ask CT **26/26**,
QUIC CT **26/26**, additional Simplex CT **12/12**, xref, Dialyzer and
diff-check, all exit 0. The two-gateway CT initially failed on both this tree
and an isolated unchanged baseline because its local observer had not yet
applied the target result. The fixture now waits on that projection's existing
events before its single public resolve. Production deadlines and feed behavior
are unchanged; there is no resubmission, and the result/exactly-once assertions
remain. Three helper tests pin subscription ordering, real wake-up, owner
death and cleanup.

Evidence, source fingerprints and all development failures are recorded in
`/tmp/quod-phase1b-cut2-UDxm1s/HANDOFF.md`; the adjacent `CLAUDE-REVIEW.md`
is the implementation-review request. Claude independently reproduced every
gate on the fingerprint-matched tree, verified the frozen vectors against
both the archived pre-cut codec and the new codec, and closed the review as
**SAFE TO COMMIT**, with no blocker or required correction. Sidecar size
accounting now measures the actual wire form rather than the native term;
this deliberate accounting correction changes no wire bytes or authority.
Cut 2 was committed as `8ca87e8`, followed by the separate 0.7.154 bump
`dd98f53`. No deployment or performance saving is claimed by this checkpoint.
Cut 3's subsequent implementation authorization changes none of the other
roadmap gates.

### Cut-3 implementation checkpoint — 2026-09-09

Only `quod_foreign_log` and its tests change in source. The existing
`parallel_probes/3` selects collect-all; its generalized `/4` carries the
completion policy through the same result/DOWN loop and absolute deadline.
Only `current_committee_confirmed` selects threshold completion. Its
request-local grouping preserves first-seen committee-peer and endpoint order;
confirmed keys and unresolved workers count distinct peers. Both terminal
booleans invoke unchanged `stop_current_probes`. The confirmation predicate,
post-advance committee, quorum calculation, transport and verifier are unchanged.

The 12 new tests cover held sent/decoding pulls reaped before the enclosing
worker completes; early impossibility; endpoint fallback on the same child;
real-owner duplicate reply replay; candidate grouping and exact result/DOWN
correlation; normal child death; the original deadline across distinct
monotonic milliseconds; delayed highest-height discovery; and agreement of
all/threshold results across 120 response-order/outcome combinations.
The original-budget trace matches exact post-response pending/confirmed counts,
so a trace of the collector's initial entry cannot satisfy a later assertion.
The false-confirmation tests deliberately stop at the collector boundary:
the enclosing request retains its existing history-recovery fallback.

An isolated old-behavior control restores collect-all only at the final
confirmation call. Both held-success tests fail with precisely
`{confirmation_did_not_short_circuit, true}` while the working implementation
passes them. The focused suite passes **119/0**. Final clean-build sequential
gates pass: EUnit **1850/0**, ask CT **26/26**, QUIC CT **26/26**, xref,
Dialyzer and diff-check, all exit 0. Evidence and the three corrected fixture
assumptions are archived
in `/tmp/quod-phase1b-cut3-G9C2s6/HANDOFF.md` with the adjacent review request.
Claude independently reproduced every gate on the fingerprint-matched tree,
verified all twelve claims and closed the review as **SAFE TO COMMIT**, with
no blocker or required correction. The test-gate plumbing follows its existing
local convention and is inert in production; no cosmetic source change was
folded into the reviewed cut. All three implementation reviews are now closed.
No hardware performance claim is made before coordinated deployment and the
matched N=4 re-measurement against the retained 0.7.152 baseline.
