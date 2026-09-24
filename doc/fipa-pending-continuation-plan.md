# Pending Request continuation — proposed contract

This proposal follows the Request prototype in `fipa-request-transactions.md`.
It is not implemented recovery behavior. The choice below must be settled before
automatic continuation is enabled.

## What the existing transaction already guarantees

The participant's completion proof reads its exact pending conversation. Its
transaction consumes that pending state, performs the domain action and records
completion at both agents. The ordinary read-set and atomic-commit checks prevent
two competing completions from both committing.

The permanent `fipa_competing_completions_commit_once_test_` holds two separately
signed proofs after both have staged the complete transition. It commits the
first, releases the second, and requires the existing `conflict_retry` refusal.
Both ontologies have exactly one completed conversation and one reservation.
The test uses explicit requests; it does not authorize automatic retries.

An already admitted transaction retains its ordinary recovery owner. Neither
this proposal nor another attempt cancels it, replaces its signature or changes
its deadline.

## The unresolved contract

The current Request rules create the participant's next signed operation only
when the hosted worker starts. Its operation ID and expiry are then volatile.
Restoring the pending conversation therefore does not establish whether that
operation was never submitted, is still pending or completed without a locally
visible result.

The settled multiwrite rule forbids a new submission while an outcome is
unknown. Its exact-redelivery exception covers an already durable claim and its
prepared application, not re-proving an unexecuted signed goal. The current
hosted-runtime contract likewise forbids automatic uncertain-write resubmission.
Changing the operation ID to a hash alone does not close this boundary: expiry
and key rotation change the signed bytes, and a queue-capacity refusal needs a
real wake edge.

There are two different promises we could make:

1. **Guarded domain continuation (recommended).** Explicit Prolog policy may
   request another attempt at a still-pending conversation after recovery,
   even when the earlier signed operation has an unknown outcome. The domain
   transaction must guarantee that only one completion can commit. Each attempt
   remains a distinct ordinary signed operation, with its own unchanged deadline
   and truthful outcome. Generic ingress and the transaction coordinator gain no
   automatic retry behavior. This is a narrow exception to the existing rule,
   not an assertion that pending state proves the previous request was unsent.
2. **Preserve the strict operation rule.** Automatic continuation must first
   acquire durable responsibility for an unexecuted goal and bind its eventual
   prepared transaction. The present transaction-custody APIs do not provide this:
   they accept already-prepared material. This needs a separate shared-ingress
   design, including interrupted proof execution, host transfer and expiry; an
   extra started flag or private request journal is not sufficient.

The first choice fits ontology-owned conversation semantics with fewer new
concepts. Its guarantee is one committed domain transition, not one proof attempt
or one signed operation. It must never be applied implicitly to arbitrary goals
or irreversible external actions lacking the existing effect guarantees.

## Implementation sequence if domain continuation is selected

1. Keep `fipa_conversation/6` as the sole durable conversation state. Derive the
   eligible completion goal in Prolog; add no asserted message history or second
   work ledger. Keep the pending-state guard and both agents' completion in the
   same existing transaction.
2. Expose successful hosted installation through the existing observed-event
   matcher, after the ordered projection frontier. Include the exact instance,
   epoch and installed owner incarnation; stale observations must be harmless.
   Use current pending-state changes and real capacity/dependency changes as the
   other wake edges. Do not replay historical events or introduce polling.
3. Reuse the existing hosted process and bounded request queue. Define stable
   domain-work identity separately from a signed attempt's operation identity.
   Suppress duplicate live queue entries. Capacity refusal must retain a scoped
   wake dependency; it must not lose later pending conversations. An unsuccessful
   completion must not produce a self-triggering retry loop. These queue and wake
   transitions require their own concrete design before implementation.
4. Exercise restart before queueing, during a proof and after durable admission;
   also exercise host transfer, a late old completion racing the replacement,
   multiple pending conversations exceeding queue capacity, and explicit domain
   failure. Require one domain effect and one completion occurrence, unchanged
   authorization/deadlines, truthful outcomes and no historical event replay.

Existing client-request outcome rules, signing-key revocation and transaction
ownership remain unchanged. Enabling domain continuation requires documenting
its specific exception in the mutable implementation contract; the pinned
multiwrite prefix must remain byte-identical.
