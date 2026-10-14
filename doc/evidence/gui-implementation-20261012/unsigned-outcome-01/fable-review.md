# Fable review: unsigned positive outcome observation (unsigned-outcome-01)

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-13. Consultative only.
Basis: `review-request.md`, `manifest.json`, `before/` against `tree/` for the
five changed files, `followup01/test/quod_physics_tests.erl` as the final test
per the parent's instruction, and read-only lookups of the ingress digest,
the exact decode layout and the parser's symbol handling. No command or test
was run; the parent's gates are the evidence and no pass is claimed here.

## 1. Verdict

Correct replacement, no shim, evidence and veto semantics preserved.
Nothing required. The production delta is one decoder helper plus the arity
change, two physics callers and their helper, the doc paragraph, and tests.

## 2. Identity and digest (verified)

- Ingress computes the committed `request_digest` as SHA-256 over the exact
  request bytes (`quod_client_goal.erl:490`). The predicate hashes the
  supplied bytes the same way, so a changed network, key, expiry or goal
  text yields a different digest and cannot match committed evidence. The
  test enumerates those four and asserts failure with the read retained.
- `decode/1` matches the full fixed layout with no tail, so trailing or
  truncated bytes are `invalid_request` and the predicate fails without a
  read.
- The agent blob comes from the same `quod_agent_ref:from_text/4` ingress
  uses, so the index key is identical for identical bytes. Parsing keeps
  every non-operator symbol as `{'$quod_symbol', Utf8}`; no atom is created
  and the goal text is never parsed.
- Namespace and anchor are compared against the scope identity before any
  index call; a foreign scope fails with an empty read set, as the test
  asserts for anchor and namespace changes. Mode is restricted to `execute`;
  a `read` selector fails with no read.

## 3. Evidence and veto semantics (verified)

- A digest or status mismatch still absorbs `{1, Agent, Id} => Token` before
  unification, so alternatives, negation and cut retain the read that
  influenced failure (unchanged code path, re-asserted by the three-mode
  test).
- Missing, unpublished or storage cases keep the live-bridge marker, now
  `{committed_operation_outcome, 2}`, and the thrown unavailable error; the
  seal refusal `non_transactional_dependency` is re-asserted.
- Verdict and reaction contexts remain a context violation (`quod_dtx_tests`).
- Registered as `committed_snapshot`, unchanged, so it is not proof-bound
  and cannot enter a policy verdict.

## 4. Callers and residue (verified)

- Both physics clauses and `physics_request_rejected/1` now pass bytes only;
  the stored custody term still carries the signature for the signed HTTP
  resolver, which is unchanged. No three-argument call remains in `priv`,
  `src`, `test` or `doc`; the exported `committed_operation_outcome/3` is the
  Erlang handler (goal, continuation, state), not the Prolog arity.

## 5. Test shape

The followup replaces the wrong `{complete, []}` expectation with
`{complete, _}`. `quod_proof_session:next/2` reports bounded failure reasons
with completion, so the exact list is not the property; the retained read set
and the empty bridge list are, and both stay as exact assertions.

## 6. Noted, no change required

- Observation no longer needs the request's signature. Anyone the containing
  proof ACL admits can observe an outcome if they hold the exact bytes,
  which include a 32-byte random operation id, so there is no enumeration.
  The bytes already carried the goal text under the signed variant.
- A selector naming an unknown agent or id yields `operation_not_published`,
  which is unavailable: the proof errors and is veto-marked rather than
  failing. Under the signed variant such a selector could not pass
  verification without that agent's key. The effect is confined to the
  invoking proof and matches the existing rule that absence is never
  evidence. A one-line test of that case would document the asymmetry
  between mismatch (fail, read kept) and missing (veto, no read).
