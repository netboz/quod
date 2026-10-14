# Network context self-review

Requested by Yan after both Claude reviewer attempts hit their provider limit.
This is the implementation author's review, not an independent second reviewer
or a Claude report. Reviewed live files against before/, tree/ and followup02/;
all ten final manifest entries match. Re-read AGENTS.md, current proof/multiwrite
contracts and the source owners. No production changes or new test runs in this
review; final gate04 remains178 tests/0 failures, true exit0,10.598s.

No blocking correctness finding in this bounded slice.

- Trust originates in the existing root-anchor owner, including the existing
  root-target rule. All fresh production contexts pass none. Only the projection
  passes a retained value obtained from validation of its own exact target.
  Request-provided bytes never populate this field. The constructor is an
  internal Erlang interface, not an authenticated ingress boundary.
- content/4 acquires before validate_content_transactions, including before
  claims are staged. Both ordinary and remote application run only after that
  whole-entry validation succeeds. No wait was added inside apply_transactions.
  Missing identity keeps the existing check abstention / committed-apply wait.
- validate_vote returns the captured context for existing-history and new-vote
  branches. prepare_observed_vote also returns it after request validation.
  Both owner validation waves and projection control batches thread that context.
  No caller still expects the old private vote_request success shape.
- Only the immutable network anchor is reused. Request expiry/block time,
  operation claims, target, current agent key and invocation authorization retain
  their existing checks. A captured anchor is not a cached admission decision.
- Every new/5 caller was migrated to new/6; no shim or abandoned export remains.
  Read-only plan validation and the pure OCC interface are intentionally unchanged
  in this slice. They still need the negative-expiry integration before any such
  result can be enabled. No negative dependency currently enters them.
- The final fixture tests actual projection entry processing: exact unchanged
  projection on missing network before a two-transaction batch; both facts after
  availability; a new signed operation after readiness disappears. The wrong-
  network assertion remains invalid_request_auth. Twenty repeated content/vote
  validations run under the existing trace barrier and assert no history reads,
  projection rebuild, file writes or syncs. Failed earlier fixture variants remain
  evidence; neither is a reason to weaken production behavior.

One reporting correction: quod_prolog:apply_step constructs a projection per
block and install_committed_projection retains only applied/est/outcomes. The
hosted owner therefore reacquires network identity for a later block. Its whole
current batch retains the value, which meets the pre-batch invariant. The foreign
projection retains its projection across entries. The direct projection fixture
demonstrates that object's reuse across entries; it does not establish cross-block
network caching in the hosted owner. The root lookup is a bounded existing owner
lookup, not history replay or a fresh disk index. Do not add a second persistent
network authority merely to eliminate it.

Review scope is closed under Yan's explicit self-review instruction. Claude has
not reviewed this implementation. No need to wait for its quota reset to continue
the authorized GUI work. This does not close QUD.25 or establish hardware acceptance.
