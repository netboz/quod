# Observation in the existing agent work owner

The remaining gap is precise progress notification for an accepted request after
actor recovery. Retained question rows already survive recovery, and exact outcome
reads exist. Recovery must never dispatch gui_complete again. The current finite
work pass always executes a fresh goal, and its dependency basis sees facts but
not exact request progress or a certified prefix crossing a request deadline.

Use the existing agent_work_goal/5 selector, finite pass, actor queue, signing and
read ingress. Make its selected request explicit: execute(Goal) for existing FIPA
and fixture callers, observe(Bytes) for exact outcome observation. Migrate those
callers and remove the implicit execute form. Observe becomes a signed read of
committed_operation_outcome(Bytes, Status); it never signs/submits the retained
execute bytes. The ordinary agent_request_finished notice reports its read result.
GUI composition provides the narrow signing/entry grant only while that actor's
submitted question retains the exact bytes. No automatic cancellation write is
introduced; the human retains the existing certified-negative cancel action.

Selection remains a pure Prolog verdict. After selection the runtime validates
canonical request identity against its own actor/ontology and records only exact
request key and expiry in the existing resource dependency basis. No outcome query
occurs in the selector. The queue then performs the ordinary signed read. Terminal
or unavailable results both advance the finite pass; completion never resets it.

Carry existing projection selection deltas on runtime_snapshot_advanced through
the existing ordered snapshot queue. Add a certified-time crossing delta to the
shared projection's publication, using the same retained timestamp index. The
resource basis matches exact request keys or Before <= Expiry < After. A block
unrelated to the request and not crossing its deadline does not wake the observer.
Queued deltas also participate in selection supersession, closing the race between
selection and installation. No new process, polling timer, durable inventory,
whole-parent invalidation, time-advancing write or outcome authority is added.

GUI's pure selector visits submitted question ids with the existing cursor and
selects observe(Bytes), under the authored completion allowance. Recovery discovers
retained obligations but only reads them. A crash before initial live dispatch
may leave the question unresolved until certified expiry; this is intentional
under the no-resubmission contract, not an eventual-execution promise.

Required tests: observe through the real recovered actor; retained execute never
submitted; exact request and certified-time invalidation; unrelated updates and
unchanged reads cause no work/history rebuild/write/sync; actual terminal update
is seen; selector races and current finite-pass/custody tests continue passing.
This candidate is not yet implemented or validated.
