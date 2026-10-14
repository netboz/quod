# Fable review: original completion dispatch through existing reactions (dispatch-provenance-01)

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-13. Architecture
consultation only. Basis: `candidate.md`, the frozen `tree/` (runtime as of
just before source-notice-01), `recovery-contract-02/candidate.md` and its
`assessment.md`, `doc/runtime-and-agents.md`, `doc/proofs.md`, the
`quod_prolog` attach contract, and the source-notice-01 correction applied on
top. No command, test or production edit was run.

## 1. Verdict

With the source-notice correction applied, I found no path by which the
existing runtime delivers the same original actual assertion twice after it
may already have dispatched. Every failure path I traced loses the occurrence
rather than repeating it. The provenance gap the candidate names is real, no
existing owner supplies it, and the proposed fix sits in the right owner (the
reducer that already sees the applied operations). The exact-bytes actor mode
is consistent with the recovery contract. Required conditions are in section
5. Nothing here recommends re-dispatch after an unknown outcome;
`duplicate_operation` is a validator refusal, not a permission.

## 2. At-most-once under the existing runtime (traced)

Local occurrences:

- One envelope per live-applied transaction reaches the attached runtime on
  the direct channel; the property channel is ignored (`quod_runtime.erl:509-527`,
  `quod_prolog` attach contract items 1-2). The reducer keeps every
  transaction's events and never merges or repeats them
  (`coalesce_changed_heads/1`).
- A batch is removed from the queue when its runner starts. On runner
  failure or budget kill the queue is dropped, actors are stopped and the
  runtime collapses to one reconciliation at the newest snapshot
  (`execution_failure/2`, `kill_runner/1`). After reconciliation
  `drop_stale_queue/1` discards local items at or below the reconciled
  height. Reactions already handed to an actor before the kill are not
  re-run; later ones in the batch are lost.
- During `reconciling` envelopes are queued, then filtered by height at the
  live transition; during `booting`, `replaying` and `unhealthy` they are
  dropped. A new runtime incarnation attaches at a fresh ready edge and sees
  only later envelopes. Replay applies rebuild D only (`apply_entry/3`
  `replay` origin).

Remote occurrences:

- One outstanding notice per consumer, whole heights per notice, resnapshot
  baseline for a new or re-established follow, coalescing to a resnapshot
  that carries no publications, and now the verified-height filter
  (source-notice-01). None of these can re-present a height already
  consumed.

Hosting:

- Reactions fan out to the actors the runtime hosts at that height; the
  GUI guard on the row's responsible actor leaves one executor. A node that
  stops hosting the actor at height Hc cannot sign for events after Hc
  because the signing read checks committed hosting; a node that starts
  hosting at Hc had no hosted actor when earlier events were dispatched and
  never sees them again. There is no simultaneous-host window in which both
  dispatch, because each node's signing read runs against a committed
  snapshot that already contains the host change for any event after it.

Actor queue:

- A queued request waits for projection release and is lost when the actor
  stops; a started request is a single worker whose deadline kill reports
  `outcome_unknown` with the operation reference and is never restarted
  (`quod_agent.erl:95-131, 44-55`).

Consequence: the live event is at most once per committed occurrence, and
the loss cases are overflow acknowledgement, coalesced resnapshot, collapse,
restart, host change and queue expiry. Each strands the intent until the
certified expiry contract retires it. The candidate states this; it should
list these cases explicitly so nobody later adds a retry to "fix" one.

## 3. The provenance gap and whether an existing owner closes it

`diff_to_events/1` maps `{assert, {Fact, {[], false}}}` and `{event, assert(Fact)}`
to the same `assert(Fact)` (`quod_runtime_predicates.erl:218-229`). The
applied operations carry the distinction; the reducer discards it. I looked
for another owner that already distinguishes them:

- The reaction context exposes recovery, physics, ceiling, mode and source
  metadata, nothing about the triggering operation (`run_reaction/6`).
- `current_request_operation/1` is a context violation in reactions
  (`quod_reaction_metadata_tests.erl:145-150`), correctly: the reaction is
  not the request.
- The committed snapshot at the event's height shows the row exists, which
  an explicit event can only forge if the row also exists. That is why the
  ACL narrows exposure but is not provenance: an authorized writer who
  commits `trigger_event(assert(Row))` for a real row would otherwise cause a
  second dispatch of the same bytes.

So no existing owner provides it, and the right place is the reducer that
already has the operation in hand, as proposed. The shape I would hold it
to: one occurrence per operation (the reducer is a one-to-one filtermap, so
each event has exactly one origin), the origin carried as executor metadata
beside the existing recovery and physics entries, and `committed_assertion/1`
a reaction-only predicate that unifies with that single origin fact when the
origin is an asserted fact clause, fails for an explicit event, and raises a
context violation outside a reaction. Owned observations, physics notices
and recovery envelopes carry no origin and so fail it. Public `react_on`
unification is untouched.

Accepted consequence to write down: an authorized writer can still commit a
genuine second `assertz` of an identical submitted row (Prolog allows
duplicate clauses). That is a real assertion and will dispatch the same
bytes again; the validators refuse the second as `duplicate_operation` if the
first committed, and if the first is unknown this is a deliberate rewrite by
an authorized owner, not a runtime fault. The question entry grants prevent
`gui_submit/4` from doing this; only a broader grant can.

## 4. Exact bytes through the existing actor

The candidate's mode is consistent with the recovery contract and with the
request-codec packet. Points that must hold:

- The mode decodes the retained bytes to the request map and rebuilds the
  typed term from it, then checks that `encode_typed/1` of that term equals
  the retained bytes byte-for-byte. This single equality subsumes the
  per-field checks and makes any drift a refusal.
- Binding checks: decoded actor equals the hosted binding reference,
  decoded key equals the binding's current active key, mode is `execute`,
  and the goal text equals the formatted exact bound goal the reaction
  selected. Key mismatch is a refusal, never a re-sign (recovery-contract R1).
- The operation reference for `outcome_unknown` comes from the decoded
  operation id, not a minted one (`start_request/5` mints today; the new mode
  must not).
- The reaction's request expiry stays the queue ceiling (`run_reaction/6`
  requires `Expiry =< UpperExpiry`); the bytes' `not_after_ms` governs
  signing and admission only. The two must not be conflated or the retained
  allowance would be rejected at match time.
- "Row and bytes still current" at reaction time is trivially true, since
  the match runs against the block-final snapshot in which the row was just
  asserted. The check that matters runs at signing time inside
  `can_sign_agent_request/3`'s committed read-only session: the row must still
  be `submitted` with these exact bytes. Put the check there.

## 5. Required before enabling dispatch

R1. Provenance metadata per occurrence as in section 3, with the reaction-only
accessor and context violation, plus a test that an explicit
`trigger_event(assert(Row))` for an existing row matches the public pattern
but fails `committed_assertion/1`.

R2. Exact-bytes actor mode with the byte-equality check and decoded operation
reference, and a test that the timeout result names the retained operation.

R3. Signing-time policy clause that requires the row current with the same
bytes, and refuses on key or host mismatch.

R4. Installation invariant: exactly one shared completion `react_on` clause
per responder ontology. Two candidate clauses would each queue the same bytes
(`dispatch_candidates/7` runs every matching clause for every hosted actor).
A test that composes the behaviour twice and asserts one dispatch would pin
it.

R5. Observation-only recovery needs the signature-free outcome read from the
recovery contract; today `resolve` mode requires bytes plus signature
(`invoke_live/4`). Until that read exists, work passes can select nothing
for retained unsigned intent, which is acceptable but must be stated.

R6. Document the loss cases from section 2 as the complete list, and that
each ends in certified expiry, not retry.

## 6. Not a counterexample

I considered and rejected: batch retry after runner kill (queue dropped,
not re-run); reconciling-mode double enqueue (height filtered); property
channel double delivery (ignored by contract); same-height multiple
transactions (kept distinct, not repeated); foreign re-follow after
`foreign_log` restart (resnapshot baseline); duplicate certified notice
(fixed in source-notice-01). None delivers an already dispatched assertion
again.
