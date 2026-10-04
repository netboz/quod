# Runtime replay completion contract (R)

Baseline: `b3a9421` (0.7.161). Approved for implementation on 2026-09-10;
exact-tree implementation review remains mandatory before commit.

The original proposal and the user's review ruling are retained below. The
ruling resolves the placement decision and adds three requirements; it takes
precedence wherever the proposal left that choice open.

## Proposed correction contract — requires review

Separate runtime replay-interval completion from the already-established proof
readiness acknowledgement. Each completed replay path must provide an explicit,
ordered closure even when Prolog was previously acknowledged ready. Preserve
the existing guarded boot/proof readiness semantics and exact owner checks.

The narrow producer-side correction should reuse existing lifecycle messages
at actual replay completion, not introduce runtime polling, timers, a second
owner, or a marker on every unrelated progress callback. It must cover member
recovery and observer gap-fill, including an idle tip with no later live block.
Do not conflate a verified partial window with quorum-corroborated admission
to voting. The exact placement of the closure relative to window completion
versus corroborated recovery is the required contract-review decision; no
unreviewed choice has been installed.

Required acceptance and fail-before controls:

1. Already-ready member catch-up ending at an idle tip: one correlated ready
   publication after all preceding apply casts, then runtime live at the actual
   applied floor without another user write.
2. Observer gap recovery, and the existing settled live-feed fast path, each
   with its own caller test; no spurious replay intervals for the live path.
3. Initial boot/unconfirmed recovery still cannot open the proof gate early;
   dependency/projection failures and a partially consumed prefix remain gated.
4. A stale recovery worker or stale Prolog incarnation cannot acknowledge or
   close work for the current owner. A Prolog restart during dispatch preserves
   rebuild ownership and does not trust the old Boolean acknowledgement.
5. Completion overtaken by a newer certified live tip closes at an actually
   consumed floor, preserving the existing `Slot >= H` recovery rule.
6. Duplicate/empty replay and subsequent ordinary ticks do not add a repeated
   reconciliation or an acknowledgement loop.
7. Snapshot readers are reaped before detachment/replacement; pending ready
   edges and replay-ID dedup remain intact. Replay never re-emits live effects.
8. The old implementation fails specifically on missing closure; a deliberately
   early/unconditional close fails ordering/readiness controls. Do not manufacture
   success by directly calling mark_ready from the acceptance fixture.

After contract review: implement narrowly, promote permanent regressions, retain
full failed logs/true exits, run the clean sequential gates, obtain exact-tree
implementation review, then commit/bump/deploy under the standing workflow.
No deployment or campaign mutation is authorized merely by this draft.


## Approved review ruling (verbatim)

Diagnosis CONFIRMED at every seam, and the correction contract is APPROVED — with my ruling on its one open decision, plus three amendments. This is ready to relay to GPT for implementation.
I verified all six code seams in the committed tree (b3a9421, 0.7.161). The gap is exactly as stated: a replay interval opens on the first advancing replay-origin apply regardless of whether Prolog is already ready (quod_prolog.erl:6919), but the closing marker is only ever requested when prolog_ready = false (quod_simplex.erl:14544) — so an already-acknowledged Prolog's catch-up interval waits for a later live block that an idle namespace never produces. One addition to GPT's finding: there are two lying comments, not one — besides the sync-completion comment, quod_prolog.erl:6916 itself promises "Simplex explicitly casts mark_ready after every completed recovery". The fix should make the code match that comment.
The probe is sound: SHA-256 matches exactly, the TEST helpers it uses pre-exist in the committed tree (no source was edited), replay enters through the real apply_entry(…, replay) casts, and the recovery scenarios drive the actual production sync_done {ready, H} clause. All five outcomes in the retained log match, true exit 0. The live read's signature — runtime stuck replaying at 1381, Prolog applied 1383 and ready, same replay ID, both mailboxes empty — proves omission, not a lost message.
One connection GPT didn't claim: this is the same signature as our standing open item — the post-crash runtime stuck at replaying-1302 / applied-1304. R is its plausible root cause; the fix's hardware acceptance should confirm that node closes.
Closure belongs at the dispatch-path completion seams — exactly where maybe_mark_ready is invoked today — never per catch-up window. Member recovery delivers many windows while pulling; a per-window closure would close and reopen the interval once per window, costing a runtime reconciliation and a snapshot-reader kill cycle each time — exactly what control 6 forbids. The member seam (sync_done {ready, H}) is already corroborated by the existing Slot >= H rule, so this places closure at corroborated recovery for members while the observer/feed settle path keeps its own completion point. The correction is then minimal: stop suppressing the interval-closure request when prolog_ready = true. The proof-readiness acknowledgement handshake stays byte-identical — it's already pid- and height-gated on the Simplex side, and a re-acknowledgement from an already-ready Prolog is already inert there.
1. Owner-channel ordering, by construction. The closure request must be emitted from the Simplex owner process on the same cast channel as the replay dispatches (as keep_progress already is — and both apply_entry and mark_ready are casts to the same server, which I verified). Per-sender FIFO then guarantees the closure arrives after every apply of its own interval and before any dispatch of the next recovery — so a stale closure can never truncate a successor interval. Never emit it from the recovery worker or a spawned helper; assert this in the acceptance controls.
2. Closure is a request to the interval owner, not a state assertion. The producer forces no ID and no floor — Prolog closes at its own applied height with its own ID (the existing clause at quod_prolog.erl:1492 already has this shape), and the runtime's existing ID-dedup stays the sole consumer-side dedup. The overtaken-by-live case then degrades to the existing inert re-acknowledgement with no double replay_ready — assert that too.
3. Fix both comments, keep the guards. The two drop-guards on mark_ready (pending network-identity dependency, projection failure) must keep dropping the closure — a blocked or failed Prolog must not fake a clean close; control 3's fixture should cover at least the projection-failure arm.
All eight controls are approved as written — control 8's two-sided fail-before (missing closure AND deliberately early close) plus the no-direct-mark_ready-from-fixture rule are essential and stay.
R does not close c4 — GPT's own attribution limits are correct (eight roots of 0.8–1.4 s with only a begin event cannot explain 19–30 s requests), nor the +8.7% serial number, nor any campaign gate. The O analyzer timestamp correction is a separate review when it arrives. B-EUNIT-UNIDENTIFIED-01 stays open with cause unassigned — correctly not counted here, since no combined suite ran.
Side checks: your write-lanes fingerprint verified intact (f0de37bf…, exact); the notification changes are benign — the script sends a fixed, content-free toast with a 5-second bound, and the AGENTS.md note honestly states delivery isn't guaranteed. Workflow after GPT implements: permanent regressions, full sequential gates with retained logs and true exits, then exact-tree implementation review here before any commit — the campaign stays stopped under its original label throughout.

## Implementation notes (not an amendment)

The two approved completion callers are the current member recovery's
`sync_done {ready,H}` callback and the settled observer's `finish_feed_replay`.
They request closure from the Simplex owner through the same cast API used by
its replay dispatch. No interval ID or target floor travels in that request.

A literal removal of the acknowledgement guard at *every* `keep_progress`
caller would violate the no-per-window rule: observer feed windows and ordinary
ticks also enter that helper while sync remains ready. The implementation
therefore distinguishes ordinary progress from completed member replay with a
call-local `ReadyBoundary` argument. Ordinary progress retains the original
initial-readiness guard; completed member replay and explicit feed completion
also request closure when acknowledgement is already true. This adds no state
record field, owner, queue, timer, persisted flag, public API, or wire format.
An isolated global-guard-removal control must fail the observer multi-window
regression while its member control passes.

Both Prolog refusal guards, its chosen ID/applied floor, the runtime dedup and
snapshot-reader lifecycle, and Simplex's exact pid/height acknowledgement
clauses remain unchanged. The new tests use real N=1 founding, signed/certified
entries, store and journal, Prolog and runtime. An OTP fixture delegates to real
Simplex init/callbacks/actions/terminate and arranges worker capabilities and
observer role; it does not claim a network quorum-recovery campaign. Closure is
never supplied by a test's direct mark_ready call.

The original stopped campaign, C4 latency cause, serial +8.7%, all hardware and
attribution gates, the separate O analyzer scope, and B-EUNIT-UNIDENTIFIED-01
remain open. Hardware acceptance after reviewed deployment must verify the
idle replay interval closes; a restart alone is not proof of that property.

