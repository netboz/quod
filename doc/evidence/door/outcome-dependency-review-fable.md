These are the eight corrections from the first validation report, restated with the follow-up clarifications folded in. Nothing new was reviewed; the verdict stands: implementable, and real dependency support once these are in.

1. **Extraction silently drops the new key.**
   - `read_set/1` keeps only keys shaped `{Name, Arity}` with an integer arity ([quod_erlog_db_local_prove.erl:543](/home/yan/src/quod/src/quod_erlog_db_local_prove.erl:543)).
   - An outcome entry would be recorded in the table and then left out of the sealed plan and transaction.
   - Until that filter is extended and has a fail-before test, the bridge is an exemption in practice.

2. **The conflict descriptor crashes on the new key.**
   - `conflict_functor/1` calls `atom_to_binary` on every read key ([quod_dtx.erl:601](/home/yan/src/quod/src/quod_dtx.erl:601)).
   - Outcome keys must be excluded there, at both seal and `materialize_decoded` ([:578](/home/yan/src/quod/src/quod_dtx.erl:578)).
   - Partition with a classifier exported from `quod_read_set`, after the pair list has passed shape validation. "Anything that isn't `{Name, Arity}`" would let a malformed key hide from both the descriptor and validation.
   - Audit for any place that assumes `read_functors` equals the length of the descriptor's `reads`. An outcome-only plan will have a positive count and an empty reads list.

3. **A definite mismatch must be `{conflict, Key}`, not a new verdict.**
   - Every lane already maps a conflict deterministically:
     - ordinary apply rejects with `conflict_retry` ([quod_committed_projection.erl:301](/home/yan/src/quod/src/quod_committed_projection.erl:301));
     - an atomic vote is refused ([quod_commit_validation.erl:741](/home/yan/src/quod/src/quod_commit_validation.erl:741));
     - a remote application is rejected through the whitelist ([:485](/home/yan/src/quod/src/quod_commit_validation.erl:485)).
   - A new error atom would fall outside the whitelist and become `{invalid, _}`. At apply that halts every honest node on a certified block, so one admitted host could stop the chain with a forged token.
   - The lane distinction stays as it is: ordinary writes are not checked before ordering, and apply is the durable rejection point. Only a malformed pair is content-invalid, through the existing shape check.
   - An index or storage error is a third outcome, separate from ok and conflict. It must travel as the existing `{outcome_error, Reason}` arm through all three callers of `validate_prepared_occ`. Returned as `{error, _}`, it would be certified as a refused vote ([:656](/home/yan/src/quod/src/quod_commit_validation.erl:656)) or judged an invalid block ([:479](/home/yan/src/quod/src/quod_commit_validation.erl:479)).

4. **Unavailable evidence must be structurally unable to authorize a diff.**
   - A throw covers negation, but a Prolog catch or the action evaluator's rollback "on failure or error" could swallow it.
   - Call the existing `record_live_bridge/2` before throwing ([quod_erlog_db_local_prove.erl:583](/home/yan/src/quod/src/quod_erlog_db_local_prove.erl:583)). The existing sealing veto then blocks any material diff that outlives a swallowed error. No new flag is needed.
   - The veto applies only to a non-empty diff ([quod_dtx.erl:274](/home/yan/src/quod/src/quod_dtx.erl:274)). An effect-only plan or a read-only answer can still seal after a swallowed error. The contract text should say "cannot authorize a diff", and a test should pin the effect-only case.
   - A successful terminal read carries its exact tracked dependency and no marker.

5. **Validation must depend on heights, not on what the index happens to hold.**
   - Operation and transaction rows survive a reopen, so on replay a row can already show a terminal state from a later slot.
   - Pending transaction rows exist only on the submitting node ([quod_outcome.erl:923](/home/yan/src/quod/src/quod_outcome.erl:923)).
   - The rule: every evidence height ≤ publication height ≤ parent, plus exact field equality. Pending and not-found both count as a mismatch.
   - For group results the publication height is the Complete slot. Group rows are cleared at reopen and rebuilt by replay ([:214](/home/yan/src/quod/src/quod_outcome.erl:214)); a future fast restart must persist them.
   - The pinned height in the token is redundant once this rule holds. Dropping it makes a token a pure function of the evidence.

6. **The wire shape must contain no atoms.**
   - The codec treats an atom and a same-named symbol as aliases ([quod_read_set.erl:64](/home/yan/src/quod/src/quod_read_set.erl:64)).
   - Use a 3-tuple key with a binary or integer tag. 2-tuples sort before 3-tuples, so existing bytes and the `Previous < Key` order check are preserved.
   - Use a closed status alphabet (committed, rejected, aborted) and carry no rejection-reason atom.
   - `read_functors` already counts map size and is checked by `exact_length` ([quod_dtx.erl:526](/home/yan/src/quod/src/quod_dtx.erl:526)), so outcome entries fall under the existing cap.

7. **The bridge must check `ctx_kind =:= proof` itself.**
   - The query class is allowed in `verdict` and `reaction` ([quod_predicates.erl:394](/home/yan/src/quod/src/quod_predicates.erl:394)), and the membership verdict runs inside validation ([quod_commit_validation.erl:832](/home/yan/src/quod/src/quod_commit_validation.erl:832)). An owner call from there would be a self-call.
   - The precedent is `request_resource` ([quod_runtime_predicates.erl:257](/home/yan/src/quod/src/predicates/quod_runtime_predicates.erl:257)).
   - Order inside the handler: kind check first, then record the marker, then throw. `record_live_bridge/2` raises `badarg` on an unwrapped state ([quod_erlog_db_local_prove.erl:597](/home/yan/src/quod/src/quod_erlog_db_local_prove.erl:597)).
   - Membership transactions skip read validation ([quod_committed_projection.erl:258](/home/yan/src/quod/src/quod_committed_projection.erl:258)), so sealing should refuse an outcome dependency on a membership diff.
   - `agent_identity_reads_current` will never be current for a read set containing an outcome key. That fails closed; choose it deliberately and test it, or pass that site the index.

8. **Door classification of an errored store.**
   - A store proof that throws unavailable returns a non-`failed` result, which the actor reports as `custody_unresolved` ([quod_agent.erl:216](/home/yan/src/quod/src/quod_agent.erl:216)).
   - The simulator would then fence a write that certainly did not happen.
   - Classify it as certainly unsent, and allow one replacement attempt per verified-rejection edge so it cannot loop.
   - I did not verify how a thrown proof error is normalised for the actor; check that before relying on the result shape.
