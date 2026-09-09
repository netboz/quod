# Catch-up page credit

**Status: A2 grammar, single-producer lifecycle and within-budget recovery
correction reviewed and endorsed; A1/A2 implementation review closed at
1756/0 EUnit, 26/26 ask CT and 26/26 QUIC CT. A3/A4 are implemented; the
complete-cut source gates pass at 1799/0 EUnit, both CT suites 26/26, xref and
dialyzer, independently reproduced. The completed cut is reviewed and approved
for commit, bump and coordinated development deployment for measurement.** Claude's
quiet-recovery follow-up accepted §6.1's counterexample and withdrew the claim
that clearing a hint leaves no work to fetch. The accepted cut consumes attempt
permission without erasing known lag and charges view capture to its operation's
original deadline. After-terminal quiet-source recovery remains the explicit
boundary in §6.2, not an implementation promise. This approval does not
authorize later performance phases or close the result-authentication gate.
[Performance roadmap §3.3](performance-roadmap.md#33-implementation-slices)
owns Phase-1A sequencing.

## 1. One producer per actual outbound link

Accept concurrent logical pulls in their existing producer-owned rows. One
page grant permits one request on an authenticated catch-up link; the terminal
page response carries its successor grant. Healthy pressure resumes directly
from that response, without busy, silent drop, or a retry clock.

The source inventory gives a simpler binding than cross-producer arbitration:

| producer / target form | existing connection pool key | producer for this channel |
|---|---|---|
| catch-up pull by node key | ordinary `Target` | registered `quod_catchup` for Namespace |
| catch-up pull by endpoint | `{identified_endpoint, Endpoint}` | the same catch-up owner |
| foreign-history page | `{directory_pinned, NodeKey, Endpoint}` | node-wide `quod_foreign_log` |

These are distinct keys in `quod_quic`'s one connection map.
[quod_quic.erl](../src/quod_quic.erl)'s `ensure_conn`,
`ensure_pinned_conn`, and identified-open handler establish the pools.
[quod_conn.erl](../src/quod_conn.erl)'s `handle_open` and `handle_send`
reuse one outbound link per channel *inside that connection*; peer-opened
links are not inserted into that outbound cache. The only production page
producers found by the `blocks_req` send-site sweep are
[quod_catchup.erl](../src/quod_catchup.erl)'s `drive_binding/2` (after
`begin_pull` / `finish_open/4`) and
[quod_foreign_log.erl](../src/quod_foreign_log.erl)'s `drive_page_binding/2`
(after its `pull_page` handler).

Thus existing concurrent pulls share a producer, not a cross-producer broker.
Different foreign anchors with the same Namespace still share the *same*
foreign-log process and channel; they require multiple retained rows, not
another scheduler. A previous timed-out read can also overlap a later logical
request, so this does not revive the withdrawn server busy-refusal proposal.

**Reviewed simplification:** bind each outbound catch-up link to its one
existing producer PID and exact local binding reference. Repeating that same
binding is idempotent. A different PID or a new binding reference must not
silently inherit its grants or operations: retire/reset that exact link and
establish a fresh generation for the replacement binding. This is
owner-incarnation cleanup, not an arbitrary capacity rejection. Do not merge
pools, create extra per-call streams, or add cross-owner tickets, offers,
interest deadlines, or a generic scheduler.

One grant is a protocol service invariant, not a limit on calls, identities,
links, follows, or histories. A later pipelining change needs its own review.
The existing catch-up owner, Simplex view, page reader, foreign-history
verifier/cache, directory, and transport owners remain authoritative for their
respective concerns. No new owner, cache, route store, or proof-engine path is
introduced.

## 2. Single wire grammar

Keep the current channel `term_to_binary({catchup, Ns}, [deterministic])`,
outer `{catchup, Ns, CanonicalInner}` envelope, length-prefixed link framing,
and bounded `quod_safe_term` canonical codec. Accept exactly:

```erlang
{blocks_credit, Grant}
{blocks_req, Grant, ReqId, From, To}
{blocks_resp_bytes, Grant, ReqId, EntryBlobs, CapturedHeight, NextGrant}
{blocks_err, Grant, ReqId, Reason, NextGrant}
```

- Grants and request IDs are 128-bit binaries. The server creates unpredictable
  fresh grant nonces; the producer creates request IDs. A successor differs
  from its current grant. Retain no unbounded used-nonce/replay registry.
- Namespace must match the authenticated channel. Preserve existing positive
  `From`, `To >= From`, and nonnegative height domains; add no history ceiling.
- Entry blobs remain canonical bytes. Apply the existing page entry-count,
  encoded-entry-byte, and complete transport-frame bounds, including the larger
  grant envelope. Re-prove maximum-page/singleton headroom, not larger limits.
- `Reason` is exactly `not_ready | server_error`. Empty success is distinct.
  There is no busy, wire cancellation, page ACK, or credit-only successor.
- Bootstrap `blocks_credit` is legal once. Every later grant rides the terminal
  page response itself; there is no additional acknowledgement round.

This is one coordinated wire cut: delete old arities and compatibility paths.
The stream opener requests pages; the receiver serves them. Reverse pulls use
the peer's existing outbound link. Enforce these roles as a new catch-up wire
invariant, matching current production sends.

Do not add an Anchor field for scheduling. Current `pull/4` supplies Namespace;
the server serves its own identity-bound committed view, not a claim that it
matched the caller's anchor. The existing caller-pinned history verification
still establishes exact ontology identity and authority. A grant proves neither
a valid page nor a current committee.

These are A2's current complete-entry page bounds, not a permanent bound on
logical witness size. [F1's history-transport cut](finality-round-recovery-plan.md)
later replaces this same grammar with proof-span paging at the same serving and
verifying owners. Credit paces those future pages too; add no second chunk
service, speculative cursor fields, or F1 implementation here.

## 3. Bootstrap and direct producer progress

After TLS/header binding, send the existing empty authentication ACK frame and
initial-credit frame as **one ordered internal send item**. They remain two
framing frames, but neither can pass a refused predecessor. Install spendable
server credit only on local send acceptance.

For catch-up, the outbound link reports `link_up` only after validating both
ACK and initial grant, split or coalesced. **Capture one absolute ACK deadline
at outbound bootstrap start**, carrying its remaining budget through every
partial ACK/grant read. This changes current `quod_link:await_ack`, whose
recursive receives restart the timeout on partial chunks; retain its configured
bound, not that restart behavior. Retain credit before the producer binds;
reused-link callbacks never mint another grant. An inbound link does not rely
on an application `link_up` callback.

Credit does not claim namespace readiness. If a correctly credited request has
no registered catch-up owner, the link returns `not_ready` plus its successor
through the same terminal-send transition. Do not publish into an absent
subscriber or wait silently for an owner.

Keep range, target/endpoint, original deadline, request ID, and exact
opening/link binding in the existing catch-up `pending` or foreign-log `pulls`
row. The producer selects its oldest runnable row by admission order. Unsent
rows contain semantic request data, not a duplicate queue of encoded frames.

Coalesce opening work per producer/target/channel binding, not per waiting
row. Preserve the three existing routing pools. Pinned and identified opens
already return references; add a tagged ordinary open through the same
`quod_quic`/`quod_conn` path using its existing tagged-waiter support.

The link delivers initial credit and terminal results directly to its bound
producer. That producer consumes one credit for one submitted row, then waits
for its page-decode completion before sending the next. In foreign-log, raw
response delivery starts decoding in the existing requesting worker; the owner
keeps the active row, original deadline, caller monitor and reserved successor
grant until the exact worker's local completion is accepted. Wire errors need
no decode turn and return successor credit immediately. No channel-wide credit
broadcast, offer/accept round trip, local offer timer, or request data in a link
interest map is needed. The link still checks exact producer/link/grant
correlation. Requests use its ordered fail-closed send path, not fire-and-forget
or best-effort send. Submission consumes local credit even while the request
frame is awaiting transport acceptance.

## 4. One reader through ordered response acceptance

The receiving link validates/consumes the grant before application publication,
resolves and monitors the registered catch-up owner, and delivers directly to
that PID with one operation reference. Replace catch-up channel fanout with
targeted request/result delivery; keep separate feed/progress subscriptions.

The catch-up owner starts its existing reader only for that admitted operation.
The worker obtains A1's `history_view(Selector, committed, Deadline)` with identity, owner PID,
captured slot, immutable snapshot, and matching projection; it reads/encodes a
bounded page and closes the reader handle. No live path fallback is permitted.
The service deadline starts at the link's valid-grant admission, before the
request waits in the endpoint mailbox; delayed admission cannot restart it.

Keep its result until worker `DOWN`: a result message alone does not prove the
worker exited. An exit without a result produces `server_error` on a live link.
Link the worker to its catch-up owner's lifetime as well as monitoring it;
normal owner termination stops workers, abnormal owner death kills them, and
deliberate linked-exit handling prevents ordinary reader faults killing the
endpoint. `DOWN`, not both `EXIT` and `DOWN`, retires the worker.

After reader `DOWN`, enqueue one response containing `NextGrant`. Keep the
operation owned until **local ordered-send acceptance**. The link then installs
that grant and reports completion to the catch-up owner before delivering any
next request from the same link PID. Same-sender order prevents next admission
overtaking cleanup. Enqueueing alone releases neither the read turn nor its row.

Extend the existing ordered FIFO item with an asynchronous correlated
acceptance receipt. Transient refusal waits for `send_ready`; terminal failure
or existing send-silence expiry resets the stream. No second send queue or
waiter process. `send_reliable/3` has the right success point after
`quic:send_data`, but its blocking API and drop-failed-item/drain-successors
behavior are not the contract to reuse.

The requester must receive the response to learn its unpredictable next grant;
local acceptance need not pretend to be peer acknowledgement. The existing
requesting verifier/probe worker (not the shared foreign-log owner) decodes each
entry blob **once**, in its existing local/wrapped-symbol reader,
and uses the existing verifier. Neither link nor envelope codec decodes entries
again for validation. Credit return does not await or replace semantic
verification. The [Phase-1B Cut-1 contract](phase-1b-codec-and-pull-contract.md#1-page-interpretation-one-retained-pull-two-local-handoff-steps)
specifies this local handoff and its cancellation races. No wire ACK or second
decoder was added; the borrowed-local-snapshot path remains unchanged.

## 5. Ownership, cancellation, and failure

Distinguish three lifetimes: an upstream verification caller, the shared
verification/page operation, and its producer/link binding.

- **Borrowed local view:** the existing queued request/worker row monitors
  the exact source owner PID carried by the view for the duration of the
  borrow. Monitor before using the view; an already-dead owner must follow
  the same `DOWN` path. Source `DOWN` retires that exact borrowed generation
  and returns typed unavailability through the existing request/result path,
  including when the call has no deadline. Active worker cleanup finishes at
  its existing `DOWN` boundary before releasing the identity's work lane;
  queued rows must not start after their source dies. Flush the source monitor
  on normal completion/cancellation. A monitor of the foreign-log server is
  not a monitor of the view's source, and before/after liveness checks alone
  cannot release a parked call. Do not cancel unrelated callers or work that
  does not borrow that dead source. Historical proof validity remains separate
  from live borrow availability; never refresh a proof or return logical false.
- **Upstream caller detaches/expires:** remove only that caller from existing
  shared work. Do not cancel its shared page, kill its verifier, or reset the
  link while the existing owner still retains that operation for other callers,
  a follow, or its existing work policy. Link reset follows actual page-owner
  termination/cancellation or the page operation's terminal deadline, not every
  `verify` caller timeout.
- **Actual page cancellation before submission:** remove its existing row. No
  grant was spent. The producer may select another runnable row immediately.
- **Actual page cancellation after submission:** reset the exact stream. Never
  mint credit, resend the cancelled row, or introduce wire cancel/tombstones.
  Other *unsent* rows remain in the same producer and reconstruct their binding
  on `DOWN`, under unchanged deadlines and existing route policy. They had not
  sent frames; an unrelated cancellation must not force their semantic retry.
- **Uncancelled submitted page loses its link:** return one typed local
  link-down failure. Its existing verification/recovery owner decides remaining
  byte sources; transport does not transparently replay that submitted page.
- **Producer dies/is replaced:** reset its exact link. A new producer cannot
  inherit its grant, request IDs, or callbacks. Reused links keep the same owner.
- **Serving link dies:** kill its exact reader and retain retiring cleanup until
  reader `DOWN`. Old results/receipts cannot attach to a replacement link.
  Catch-up owner death during an operation likewise resets the link.
- **Opening/transport owner fails:** correlate `link_error` and invalidate all
  openings owned by the lost transport generation, not just established links.
  Rebuild retained unsent bindings on the existing transport registration or
  valid route/lifecycle edge. An immediate open failure is not permission for
  an in-place reopen loop or a fresh timeout budget.
- **Final foreign-history interest ends:** use existing transport ownership/
  exact-lease cleanup to release its binding without closing another live use.
  A temporary gap between pages of still-owned verification/follow work is not
  final interest. Removing channel subscriptions alone is not link cleanup.
- **Catch-up task ends:** the existing recovery/feed worker is the borrower
  across successive `pull/4` calls. Its monitor retains the binding between
  pages and releases it on worker exit; a completed page alone is not the end
  of a multi-page task. No idle timer or unused permanent binding is needed.

All local controls/results match producer PID, link PID, and operation/binding
reference; wire results additionally match Grant and ReqId. Ignore stale local
callbacks without resetting an innocent replacement stream. Duplicate spent
grants or terminal wire responses are fatal. Request-ID reuse under a new grant
is a new operation, not grounds for an unbounded history of seen IDs.

Original caller/page deadlines remain at their existing semantic owner. Do not
copy per-row deadlines into link scheduling state or introduce an offer timer.
Carry the actual remaining page-attempt budget into producer admission instead
of silently substituting its default. Existing sent-transport failure deadlines
remain at the link. A clock can terminate stalled work; healthy sends resume
from response, send-ready, registration, route, or monitor messages.

## 6. Unavailability is not another progress loop

Owner-view refusal returns `not_ready`, never a scan. Later Simplex append does
not invalidate an admitted bounded view or make its captured height a new
current-head claim. Preserve A1's separate view and operation lifetimes.

A `not_ready` response terminates that page; returning credit must not resubmit
it. Existing semantic owners classify unavailable evidence and may choose a
remaining permitted byte source. If they retain work, the exact existing wake
must be named and proved for that path; this document does not assert that every
remote readiness transition already has an observable event.

`quod_foreign_log:finish_follow_refresh` and `continue_follow_progress`
currently reuse an old hinted height as permission to start another job after
failure. Delete that reuse: permission to attempt work is consume-once. Only
successful newly verified suffix advancement or a fresh external dirty edge
can authorize another immediate turn; failed/unchanged work cannot re-arm
itself. A fresh edge arriving during work is retained once, not erased by that
work's failure. The informational target height/lag is not this permission:
deleting it would conceal a known missing suffix without fetching it. Keep
classification at the existing foreign-history owner, not the link or proof
engine.

| outcome of an attempt | attempt permission | known lag `(L,H]` | re-arm |
|---|---|---|---|
| success: verified suffix advanced | retained for further missing pages | shrinks/clears | actual verified progress |
| no progress: nothing new verifiable | consumed | retained | fresh edge only |
| typed failure: not-ready, owner loss, link down | consumed | retained | fresh edge only |
| fresh edge during an attempt | exactly one buffered permission survives | updated | that one permission |

A successful result at an unchanged verified height is the no-progress row,
not permission for another turn. In particular, success alone does not re-arm
work. This resolves the follow-up's contradictory shorthand "unchanged-height
success": only a newly verified suffix or the buffered external edge does.

### 6.1 Quiet-target counterexample — correction approved

The review's stronger conclusion, “there is no retained work that needs waking
at an unchanged height,” does not hold for a follower whose verified height
lags an already-announced target height:

1. A private target's committed height is `H`; the follower retains `L < H`.
   `accept_feed_recipient_signal` ACKs `registered(H)`/`wake(H)` immediately,
   then stores the hinted height and starts verification. The ACK does not
   prove that `(L,H]` was fetched.
2. The same target Simplex PID is temporarily busy for more than the internal
   one-second `call_history_view` timeout. The page returns unavailable even
   though the target already has the required committed bytes.
3. After consuming the attempt permission, resume that exact PID at `H`,
   without a further commit, process restart, route change or new caller.
4. The suffix still exists. Feed recipient logic sends a later height only
   above the already-ACKed value. Private targets are not advertised;
   unchanged host advertisements do not emit an exact private-target route
   wake. There is no guaranteed event that restarts this fetch.

An actual source restart is a different, covered schedule: the namespace's
`rest_for_one` ordering restarts feed, which resets inbound feed links;
the existing registration monitor reconnects and `registered(H)` wakes the
follower. Do not use that test to claim same-PID recovery is covered.

The source seams are `quod_simplex:call_history_view`,
`quod_foreign_log:accept_feed_recipient_signal`, `finish_follow_refresh`,
`continue_follow_progress`, `quod_feed:acknowledge_recipient` /
`queue_recipient_height`, and `quod_directory:notify_usable_identities`.
The approved request-lifecycle correction removes the independent one-second
cutoff. Capture consumes the calling operation's original absolute remaining
budget, at the same owner; source death releases the borrow through the existing
request-row monitor. Caller detachment removes only that caller. A borrowing
operation with an existing terminal work deadline keeps that deadline; it is
not a detachable caller's deadline. Shared exact cache verification has no
separate whole-job deadline: its admitted active/runnable/custody-waiting job
survives caller expiry, its pages retain their original budgets, and an
unavailable-route park retires when it loses all interest. See the
[exact-reference lifecycle contract](exact-reference-lifecycle-tracing-contract.md#42-shared-work-has-a-different-lifetime).
Do not restart verification's budget
after capture. Catch-up serving uses its page/service deadline, co-hosted follow
uses its existing follow-work budget, read certification (initial and later
anchor alike) uses the proof's remaining budget, and outcome/evidence recovery
uses its operation deadline. No blanket infinity: an unbounded internal wait
requires an existing owner that actually terminates that exact worker when its
lifetime ends, not a monitor consumed only in a later receive loop.

Distinguish two tests and claims. Recovery after the old one-second cutoff but
before the real operation deadline should complete the original request,
without another wake. Recovery after the real terminal deadline is different:
cleanup is required, but eventual quiet-source catch-up still needs an actual
remaining lifecycle edge or an explicitly reviewed terminal-failure contract.
Consuming the hint alone proves neither. No silent timeout enlargement,
registration-reset retry loop, or new readiness service.

### 6.2 After-terminal recovery — explicit boundary, feed change deferred

This cut documents rather than conceals the boundary: after a real terminal
failure, a subscribed follower retains known lag against a quiet same-PID
source until a new commit, restart, route event or demand provides another
attempt. Periodic route renewal is not a guaranteed progress mechanism.

The review suggested changing feed acknowledgements and periodically resending
unacknowledged wakes. That is a separate candidate requiring focused review,
not part of A2. The current feed anti-entropy round calls `send_digest`; its
`follows` guard excludes validators, and it does not resend recipient wakes.
Adding that resend would introduce timer-driven fetch retries despite reusing
a timer. It is not authorized under the standing no-progress-polling rule.

An ACK change also needs exact semantics: `acknowledge_recipient` accepts only
the advertised in-flight height `H`, not an arbitrary verified `L` or `K`.
Remote announced height, locally certified contiguous history, and materialized
projection height remain distinct. Demand-only current-view watches deliberately
have no background materializer; a global ACK-on-materialization policy would
strand them or keep retransmitting forever. None of these semantics changes
silently with the accepted capture-budget and consume-once corrections.

## 7. Input boundary and closure gates

At the existing authenticated link, use **one catch-up raw/control decoding
seam**, backed by existing `quod_safe_term:decode_wrapped/2` for the outer and
inner envelopes. Replace the outer `binary_to_term(..., [safe])` path: reject
compressed ETF, trailing bytes, and noncanonical envelopes at both layers.
Keep `EntryBlobs` opaque here; the existing receiving reader alone decodes each
entry once. Add no second envelope parser or per-entry validation decode, and
never materialize foreign symbols in transport.

Gate one complete frame at a time. Wrong roles, grants, correlation, grammar,
and frame/page bounds reset only the offending stream
before application publication and stop the rest of that batch. Emit no stream
of busy replies; unrelated channels remain usable.

The accepted posture is prompt reset plus existing transport buffering, **no
QUIC-fork receive-credit change**. This bounds admitted application work, not
all bytes already delivered into transport mailboxes. A failed resource test
returns to review; it does not authorize a new quota or fork patch.

Delete the old wire arities and outer safe-only decode, 32-worker silent-drop
path, bare unmonitored spawn, fire-and-forget page sends, peer-only matching,
catch-up-only fanout/reference
counts, live path fallbacks, and obsolete comments/metrics/tests in A2. Keep
the foreign owner's existing per-identity work queue and independent feed
subscriptions. Local follow/cache replay/materialization use the same session
reader directly, without network credit. Add no Prolog retry path or write
resubmission; admitted continuations and their backtracking state stay owned.

Required non-vacuous gates:

1. Real pool/channel tests prove the single-producer premise, same-owner reused
   opens, different-owner generation retirement, and multiple FIFO pulls,
   including same-Namespace/different-anchor work at the foreign owner.
2. Block real ACK-plus-grant and response sends; deliver `send_ready`; exercise
   split/coalesced bootstrap and ensure no `link_up` from ACK alone, duplicate
   bootstrap grant, or successor overtaking a failed page. Dribble partial ACK
   and grant chunks: the deadline captured once must still terminate bootstrap.
3. Hold a reader while concurrent logical calls remain admitted; release it and
   finish all without busy, timer wake, or semantic retry. Serve more links than
   the removed 32 threshold with work bounded by admitted grants, not a new cap.
4. Suspend a worker after result/before exit; inject reader/owner/link death,
   late callbacks, and blocked-send failure. Prove `DOWN`-confirmed cleanup,
   exactly-once terminals, no orphan reader, and no generation cross-talk.
5. With two upstream callers sharing one verification, expire one and prove its
   page and remaining caller continue unchanged. Separately cancel the actual
   submitted page: exact stream reset, unsent-row reconstruction, unchanged
   deadlines, no cancelled resend. Cover lost openings, immediate open failure,
   transport replacement, and final-interest lease cleanup. For a local
   borrowed view, kill its exact owner while active or queued, including an
   infinite call; assert typed completion, worker `DOWN`, row/monitor cleanup,
   no cancelled queued spawn, and survival of unrelated live callers.
6. Preserve an old hinted height above the resident tip, then fail successive
   page attempts with `not_ready`: no self-loop, no new worker without a new
   valid progress edge. Prove successful suffix continuation, unchanged-height
   no-progress, and exactly one buffered edge during a failed attempt. A private
   already-ACKed `L<H` fixture must recover on the original request after a
   same-PID pause beyond the old one-second cutoff but within its real budget.
   True terminal expiry must clean up without self-waking; a later real edge
   resumes work. Do not claim §6.2's deferred guarantee from a restart test.
7. Send a hostile multi-frame batch with one grant: no violating frame reaches
   an owner, snapshot lookup, or spawn. Check repeated reset cleanup and another
   channel's progress. Enforce maximum-page/singleton framing and wrapped-symbol
   behavior, compressed/trailing ETF rejection at both envelope layers, no new
   atom growth from foreign vocabulary, and exactly one entry decode per blob.
8. Unavailable views perform zero fallback scans; valid pages use the owner
   session. Wrong anchors/certificates remain rejected. Hold a proof on page
   credit and verify the same continuation/backtracking state resumes, with no
   extra proof evaluation or write submission.

Claude approved the single-producer alternative, exact grammar, cancellation
classification, reader/send ordering and §6.1's correction. The feed semantics
candidate in §6.2 requires its own focused review if pursued. The A1/A2
checkpoint and completed Phase-1A cut are reviewed. A4's feed
edits carry writer snapshots through the existing gap-recovery sink and bind
worker cleanup to its owner; they do not alter digest/ACK/progress permission
or resolve §6.2. Complete-cut source gates and review are green; hardware gates
remain owed. No deployment or improved latency result is claimed here.
