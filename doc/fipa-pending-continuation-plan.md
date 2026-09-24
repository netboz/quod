# Pending Request continuation — approved contract

This contract follows the Request prototype in `fipa-request-transactions.md`.
Yan approved guarded domain continuation on 2026-09-24, with an explicit request
to retain the decision for later improvement. The opt-in continuation rules in
`priv/ontologies/fipa_request.pl` implement this policy through
the existing hosted runtime; deployment and acceptance evidence are separate.

**Revisitable decision:** explicit Prolog policy may initiate a separate signed
attempt at a still-pending, transactionally guarded conversation step despite
an earlier attempt's unknown outcome. Only one domain completion may commit.
This exception does not permit generic ingress or transaction recovery to retry
arbitrary uncertain operations, alter their deadlines or report them as failed.
Revisit this choice if repeated proof work becomes costly or a shared durable
admission mechanism can simplify it without introducing a second work ledger.

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
this policy nor another attempt cancels it, replaces its signature or changes
its deadline.

## The decision and its alternatives

The current Request rules create the participant's next signed operation only
when the hosted worker starts. Its operation ID and expiry are then volatile.
Restoring the pending conversation therefore does not establish whether that
operation was never submitted, is still pending or completed without a locally
visible result.

The baseline multiwrite rule forbids a new submission while an outcome is
unknown. Its exact-redelivery exception covers an already durable claim and its
prepared application, not re-proving an unexecuted signed goal. The current
ordinary hosted-request contract likewise forbids automatic uncertain-write resubmission.
Changing the operation ID to a hash alone does not close this boundary: expiry
and key rotation change the signed bytes, and a queue-capacity refusal needs a
real wake edge.

The alternatives considered were:

1. **Guarded domain continuation (selected).** Explicit Prolog policy may
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

## Runtime integration

1. Keep `fipa_conversation/6` as the sole durable conversation state. Derive the
   eligible completion goal in Prolog; add no asserted message history or second
   work ledger. Keep the pending-state guard and both agents' completion in the
   same existing transaction.
2. Reuse a founding state handler depending on `current(agent_hosting)`. The
   existing startup and child-recovery reconciliation therefore selects pending
   work. Live conversation changes select affected instances. A separate
   installation observation is unnecessary, and historical events are not replayed.
3. The handler selects one goal in the current Prolog snapshot using
   `project_next_agent_goal(Instance, Wake, Selector, Budget)`. `Selector` is a
   ground closure extended with `(Cursor, Key, Goal)`; it must select the least
   eligible binary domain key after the cursor. Keys identify domain work, not
   signed operations. Signed execution rechecks the ordinary authority and guard.
4. Before its first pass, a replacement snapshots the agent's earlier source
   transaction custody from Simplex's existing journal and committed role
   projection. It retains only group references and waits for owner notices;
   follow-up snapshots can only remove references. Its own new attempts cannot
   enter this wait set or trigger their own retry loop. This covers dormant
   responsibility before Vote as well as already committed roles. A cleared
   journal row alone is not completion: the same snapshot also checks the
   committed role to which that responsibility may have transferred.
5. The existing runtime agent row owns a volatile cursor, owning handler, watched
   revision and one outstanding request reference. The shared request admission
   and hosted worker handle the goal with unchanged queue limits, signing,
   absolute deadline and installed-frontier release. There is no second executor,
   work inventory, durable queue or goal-selection read operation.
6. Completion, including refusal or unknown outcome, advances to the next key.
   It wakes only that instance's handler through the existing ordered tier.
   Capacity refusal retains the cursor; actual capacity release wakes blocked
   handlers before the completing agent requests its next item. Old process or
   request references cannot complete work belonging to a replacement.
7. A finite pass ends when no key remains. Changes to watched state during a pass
   permit a subsequent pass, catching keys inserted behind its cursor. Unrelated
   height changes and completion wakes alone do not restart an idle pass. A
   rejected pending step therefore cannot keep itself running without new input.

The optional profile must replace any reaction that independently submits the
same completion. Its default watch list covers conversations and opt-in budget
policy. A domain whose eligibility depends on additional facts must declare
those dependencies in its founding handler; arbitrary policy changes cannot be
inferred by Erlang. Unsubmitted work remains solely in the ontology.

## Verification and revisiting

Require restart before submission, during proof and after durable admission;
host transfer; a late old completion racing its replacement; a backlog larger
than queue capacity; actual capacity refusal/release; and explicit domain failure.
Require one committed consequence and one completion occurrence, unchanged
authorization/deadlines, truthful outcomes and no historical event replay.

The current selector collects and sorts remaining pending keys on each item.
It stores no extra index, but a large backlog can require quadratic scanning.
Measure this before optimizing; prefer a shared Prolog query/index improvement
to a private work inventory. The approved exception and repeated proof cost
remain explicitly revisitable, as Yan requested.

The initial custody check conservatively waits for all earlier source groups
of that agent. A future refinement may narrow this to the selected work's actual
dependencies. Its current query scans existing in-memory pending/role rows at
the explicit recovery boundary; it does not rebuild them from ledger history.

Existing client-request outcome rules, signing-key revocation and transaction
ownership remain unchanged. The specific exception belongs in the mutable
implementation contract; the pinned multiwrite prefix remains byte-identical.
