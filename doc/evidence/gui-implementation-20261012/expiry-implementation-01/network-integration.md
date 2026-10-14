# Existing-owner network context integration

Implementation constraint, not a new domain service. Negative evidence has no
positive committed request digest, so its embedded network cannot authenticate
itself. The outcome validator must receive the existing owner's trusted network
anchor; it must remain process-free.

- Capture network identity at existing content/vote/read-certificate admission.
  The validation context may carry this immutable verified reference. Pass it
  through the projection's existing validation result into the second ordinary
  OCC check. This is verified context, not another owner of network truth.
- Extend requires_network_identity for unsigned transactions and votes whose own
  read checks contain negative evidence. Signed requests already require it;
  do not decode their plan again just to rediscover that requirement. Any added
  decode for unsigned plans is bounded wire input, never history materialization.
- Read-only certification enters validate_prepared_plan directly. After the one
  material decode, acquire trusted network context when its reads require it.
  Direct remote-application checks need that same boundary. Do not assume content/4
  ran merely because another call path normally does.
- Network absence remains typed unavailable: read certification reports unavailable,
  vote selection waits/abstains, committed application uses its existing root-ready
  subscription and wait result. It is neither OCC conflict nor outcome-index
  corruption. In particular, do not return outcome_error(network_identity):
  quod_prolog:commit_validation_result treats that as index failure and restarts
  the owner. Do not fabricate a deterministic refused Vote.
- Pure validation receives {Index, Parent, Target, Network}; require exact source
  and network, captured prefix within base/parent/published floor, exact timestamp,
  and no claim at or below captured prefix. Ignore retained claims above prefix.
- Positive terminal query keeps its existing dependency/digest mismatch behavior.
  A nonterminal claim, including a different digest, stays unavailable. No new
  claim-conflict result is part of this change.

Original caller deadlines, effect custody and unknown-write no-resubmission remain
unchanged. No negative token or expired query result has been enabled yet.
