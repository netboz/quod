# Independent plan and implementation review

Reviewer: Codex, at Yan's explicit request to perform the review while Claude is
unavailable. This is not a Claude review. The initial packet freezes 46 inputs
and records their hashes and repository HEAD. Corrections and validation below
are separate from that initial packet.

## Findings

1. **Revision precision, implementation.** The new HTTP dependency envelope
   rendered uint64 heights as JSON numbers. JavaScript rounds values above its
   exact integer range; parsing the maximum uint64 and converting it to BigInt
   gives 18446744073709551616, one past the actual height. Dependency heights now
   use decimal strings. The canonical Erlang wire still carries exact integers;
   there is no old/new decoding branch. The test crosses the actual HTTP JSON
   encoder/decoder with both sides of the JavaScript boundary and the largest
   two uint64 values.

2. **Recovery readiness, implementation.** The post-subscription snapshot
   checked only applied height. Recovery beginning between proof completion and
   subscription could be missed, leaving a matching height but an unready owner.
   The existing engine stats reply must include its current readiness, and the
   socket must retain its subscriptions while waiting for the matching ready
   notice. Registering an absent engine's name is not proof that it is ready.
   The name-follow path must take the same asynchronous snapshot instead of
   immediately asking the client to re-prove.

3. **Recovery notice identity, implementation.** Replay notices carried an
   opaque reference without their engine incarnation. A socket subscribed to
   several namespaces could not distinguish an old dependency's queued replay
   notice from its current dependencies. Recovery identity now includes the
   publishing engine PID; the consumer must match both owner and recovery run.
   Existing runtime consumers keep their one lifecycle and event channel.

4. **Incomplete navigation fence, plan.** Checking only the acting agent's
   height misses an earlier reference lookup's foreign policy dependency. The
   draft also called a nonexistent `block_height/1` predicate. The revised
   canonical view goal carries the complete expected dependency list in signed
   bytes. Its shared Prolog wrapper opens those exact anchored scopes through
   ordinary authorization; the existing socket compares their actual pinned
   heights before attachment and retains their subscriptions. This uses the
   existing read envelope and adds no height primitive or second propagation
   protocol. A mismatch requires fresh navigation selection, never omission of
   the dependency to make a stale reference work.

5. **Blocking opening, plan.** Removing the source-locality restriction alone
   leaves ingress routing/proof waits inside the socket callback. The amended
   plan uses one cancellable, monitored opening worker calling the same ingress,
   under the original signed expiry and opening identity. The existing
   `quod_process:kill_when_owner_dies/2` helper covers socket death. No new queue,
   authorization engine or trusted-operator bypass is introduced.

6. **Ambiguity and instance identity, plan.** A first successful read is not
   evidence of a singleton definition; `physics_required_configuration/4`
   enumerates alternatives. The view must explicitly require exactly one scene
   and selected configuration. Navigation must also produce the actual anchored
   space instance. The current personal-lobby reference carries only an ontology
   identity, so its representation adapter must resolve the authored instance;
   the generic browser may not guess a lobby constant.

7. **Classification must govern resources as well as views, plan.** The current
   resource projection checks `physics_space/3`; the existing hosting suspension
   hook checks only disabled configuration. A view-only class check would leave
   different eligibility rules for rendering and resource allocation. The amended
   plan requires one derived Prolog eligibility rule reused by those owners and
   live input, with the old independent checks replaced. Removing the physical
   class while leaving a bound controller cannot become observer travel. Existing
   space/control transactions own withdrawal and unbinding; an inconsistent
   authored state remains unavailable instead of being repaired by rendering.

## Checked invariants

Common physics registration uses the existing startup loader. Per-space gravity,
permissions, enablement, body/control definitions and resource policy remain in
Prolog. Neither registration nor class membership allocates a simulation.
The proposed ordinary-view wrapper selects physics at the visible space's owner,
and has no lobby branch or duplicated physical/nonphysical flag.

Signed dependency capture retains exact local and authenticated remote opening
heights, including failed alternatives and abort. Scope opening retains router
authentication state instead of overwriting it. Canonical result validation
rejects malformed, duplicate, unsorted and oversized dependency sets and nested
read envelopes. Error normalization retains valid dependencies without treating
a partial failed proof as an authorized view.

Foreign registration uses the existing asynchronous follow interface. The
foreign owner replies with the follow reference before its initial notice from
that same process. Cancellation retains an unfinished registration until its
reference can be released; it admits no second batch meanwhile. Owner death
resolves the request monitor and clears that pending cleanup. Local snapshot
aliases are abandoned on release. No polling or replacement synchronization owner
is needed.

Space admission and withdrawal already have designated source assignment and
destination placement owners in one transaction. The remote collider stage must
extend that path and the retained source projection/resource selector. Nothing
in this review substitutes a pinned copy, manually repeated adoption, live-query
write exemption or post-commit repair for those obligations.

## Validation

- `self-review-height-repro-01`: the new precision test failed as expected;
  15 tests, one failure, true exit 1, tracked inputs unchanged. The failure log
  is retained.
- `self-review-corrections-01`: 41 result-codec and foreign-lifecycle tests
  passed, true exit 0, tracked inputs unchanged. This includes owner death while
  a cancelled registration remains pending, in addition to late successful
  registration cleanup.
- `self-review-recovery-01`: all 314 Prolog, runtime, replay, physics,
  foreign-lifecycle, result-codec and outcome-endpoint tests passed, exit 0,
  tracked inputs unchanged.
- `self-review-stale-recovery-repro-01`: 1/60 tests failed as expected. A new
  assertion showed that matching only the engine still accepted a ready notice
  for another recovery run. Retained the failure and corrected readiness to carry
  the exact engine/run pair in both the owner snapshot and socket state.
- `self-review-recovery-02`: all 314 tests passed after that correction, exit 0,
  tracked inputs unchanged. A native installation notice cannot bypass pending
  dependency readiness.
- `self-review-restart-01`: both focused tests passed, exit 0, tracked inputs
  unchanged. The new test terminates a founded fixture's projection subtree,
  suspends its actual Simplex owner, and restarts the engine. The socket receives
  the actual gproc registration, samples the unready engine asynchronously,
  waits through boot and the exact replay run, then refreshes only on readiness.
  The same anchor and committed history survive. This enters at the retained
  dependency seam; it does not claim a new signed-view admission or real-world
  desktop acceptance. The other test validates the runtime's snapshot-reader
  boundary with the current owner-scoped recovery identity.

These campaigns overlap; their counts are not additive or a full-suite claim.
`git diff --check` passed. The accumulated production diff is +504/-141,
net +363 lines across 17 files; this review adds a net 50 production lines over
its initial scope. The growth carries exact recovery state through existing
snapshots and notices and handles an engine registering before readiness. It adds
no production process, polling timer, history copy or compatibility branch.

## Review conclusion

The immediate Claude-review pause is superseded by Yan's explicit request for
this independent review. The reviewed dependency corrections are locally
validated. The revised generic ordinary-view plan can proceed to implementation
with the concrete contracts and tests above; it is not implementation evidence.
Its opening worker, full navigation fences, typed-view lease renewal, shared
physical eligibility and ordinary scene/control integration remain work to do.

## Scope and remaining acceptance

The amended plan describes the next generic ordinary-view implementation; it
does not establish that implementation or release acceptance. Remote committed
collider installation through subscriptions, physical admission/edit/withdrawal
concurrency, fresh signed personal-world identity/history and real desktop
collision acceptance remain open. Existing unrelated failed measurements and
Claude quota-error packets remain intact. No deployment or live mutation is
authorized or performed by this review itself.
