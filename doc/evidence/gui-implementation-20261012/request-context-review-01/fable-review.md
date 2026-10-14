# Fable review: `current_request_operation/1` (request-context-review-01)

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-13. Consultative only.
Basis: `changes.diff` and the frozen `tree/` of this packet; `proofs.md` and
the multiwrite map as previously read; AGENTS.md as frozen in the component
packet (this packet carries no copy). `quod_predicates.erl` and
`quod_agent_ref.erl` were read live, read-only, for the registry semantics
the diff depends on. No command, build or test was run; gate logs are the
parent's evidence and are not claimed here.

## 1. Verdict

The delta does what the request says and nothing more. The operation
reference is re-derived from verified signed bytes at every target, exposed
only to `proof` contexts, classified so it never becomes a live bridge, and
retained exactly as long as the existing request expiry. I found no
authority, lifetime or identity defect. Two consequences are worth stating
in the plan, and three test gaps remain.

## 2. Verified facts

P1. **Provenance is the verified request, never a caller claim.**
- Origin proofs: `quod_proof_context:start/6` stores the ingress evidence,
  and `request_operation/0` reads `operation_ref` from it
  (`tree/src/quod_proof_context.erl:64, 110, 169`). Unsigned proofs have
  `none` and fail the query.
- Co-hosted and remote scopes: the target engine runs
  `verify_scope_authentication/10`, which calls
  `quod_client_goal:verify_for/5` on the request bytes and signature, checks
  the principal equals the agent in the evidence, and only then builds the
  request context with `operation_ref` (`tree/src/quod_prolog.erl:2252-2283`).
  That context reaches `quod_scope_session:start/9` for co-hosted scopes
  (`:1939-1961`) and `#remote_scope` then
  `start_admitted_remote_scope_session` for remote ones (`:2400-2406, 2992`).
  Nothing crosses the wire that was not already there.
- Nested asks are relayed to the origin and reuse its scopes, so the same
  reference is seen everywhere; the GUI test asserts the foreign application
  reads and writes the ingress `operation_ref` byte for byte
  (`tree/test/quod_gui_components_tests.erl:94-103`).

P2. **Scope-session invariant.** `start/9` refuses, by `badmatch`, an
operation whose agent is not the principal, whose agent identity does not
decode to the operation's namespace and anchor, or that arrives without a
binding and signed flag (`tree/src/quod_scope_session.erl:80-88`;
`quod_agent_ref:identity/1` decodes the blob). Same style and strength as the
existing expiry invariant above it; the test exercises each forgery.

P3. **Classification.** Registered `query` with dependency `proof_bound`
(`changes.diff:40-41`). In the live registry, only `live_observation`
dependencies record a live bridge (`quod_predicates.erl:376-382`), so a
write proof that uses the reference remains sealable. That is the same
dependency as `current_request_expiry/1` and `current_ontology_identity/2`,
and correct: the value is bound to the signed request, not to node state.

P4. **Context restrictions.** The registry refuses every `query` in
`policy_verdict` contexts before dispatch (`quod_predicates.erl:404`). The
predicate itself errors `{context_violation, current_request_operation,
query, Kind}` for any kind other than `proof`, so `reaction` and `verdict`
cannot obtain a reference (`changes.diff:51-64`); the reaction test asserts
the error. Within `proof`, the scope accessor is consulted first and the
origin context only when no scope runtime exists, matching the expiry
accessor's order.

P5. **Lifetime and persistence.** The reference lives in `#runtime` for the
scope worker and in `#remote_scope` for the admitted remote scope, exactly
where `request_expiry` lives, and nowhere else. No store, outcome index,
custody or counter is touched.

P6. **Fixture correction.** The read-certificate tests now build the certified
base with `quod_ct:action_kb/3`, the production shared base, on both the
session and worker sides (`changes.diff:327-347`). This makes the captured
read tokens describe the real height-zero KB, including the `no_follow/1`
facts added in the component delta. Both sides change together, so the
certification comparison is not weakened.

## 3. Consequences to state (not defects)

C1. **Membership verdict re-proofs.** A committee-changing transaction whose
rule calls `current_request_operation/1` will error in the validators'
`verdict` re-proof and be rejected. That is consistent with how
`committed_operation_outcome/3` behaves and with the multiwrite rule that
membership diffs carry no request dependencies, but `proofs.md` says only
"reaction matching and validator policy contexts"; add "membership verdict
re-proofs" so an author is not surprised.

C2. **Control and cursor proofs expose it.** Any signed mode with evidence
yields the reference, including `control` and `cursor`. That is what the
opening design needs for deriving the question identity (component review,
E6) and is correct, but it should be written down as intended.

## 4. Test gaps

- No test for the `verdict` kind reaching the predicate's own error branch
  (policy_verdict is blocked earlier and is covered by construction).
- No test that a `control` or `cursor` signed proof exposes the same
  reference as its ingress evidence.
- The foreign-scope hosting test is co-hosted; an actual remote scope over
  the router is not exercised for this accessor. The remote path reuses the
  same `verify_scope_authentication/10`, so the risk is low.

## 5. Unverified

`quod_predicates.erl` and `quod_agent_ref.erl` were read live, not frozen.
All gate results.
