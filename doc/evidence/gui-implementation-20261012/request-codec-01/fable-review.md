# Fable review: pure exact-request construction (request-codec-01)

Reviewer: Claude Fable 5.1 (claude-fable-5-1), 2026-10-13. Consultative only.
Basis: `candidate.md`, `manifest.json`, `receipt.json`, the frozen `tree/`
(AGENTS.md identical to prior packets), diffed against the last frozen copies
(recovery-contract-02 for the codec and signer, component-review-01 for the
primitives and their tests, question-view-02 for the question tests) and
against git HEAD for the vault tests. Read-only lookups in the live tree:
`quod_agent_ref:from_text/4`, `quod_wire_term:is_ground/1`,
`quod_safe_term` atom handling, `quod_committed_projection` flag setup,
`quod_erlog_db_local_prove` bridge recording, the erlog builtin table.
No command, test or production edit was run; the parent's gates are the
test evidence.

## 1. Verdict

Sound. The delta is one exported codec function, one pure primitive, one
type test, a signer that calls the shared codec instead of its own copy
(−20/+6 lines), docs and tests. No authority regression, no new execution
path, and construction stays distinct from governed signing. Nothing is
required before acceptance. One item to confirm (section 6) and two optional
test additions.

## 2. Authority (verified)

- `agent_request_bytes/2` touches no key, clock, vault, session or owner.
  Its only calls are `dderef`, `is_ground`, `encode_typed` and unify
  (`quod_common_primitives.erl:82-90`). It records no live bridge, so the
  seal/veto classification sees it as proof-bound data; the vault test
  asserts an empty bridge list for a material proof that constructs and
  asserts the bytes with no signing grant (`quod_agent_vault_tests.erl:305-309`).
- Signing is unchanged in substance: `sign_agent_request/2` still requires a
  read-only session, the scope identity to equal the actor's namespace and
  anchor, a materialized node principal, then the ordinary
  `can_sign_agent_request/3` verdict before the vault is asked
  (`quod_agent_predicates.erl:141-184`). The test that a host and key alone
  do not release a signature is retained (`:310`).
- The bytes are inert by construction: no signature, and the wire layout
  binds network, key, actor, operation, mode, parser, expiry and goal, so
  nothing decodes them as anything but a request for that exact key.
- Expiry is deliberately not checked at construction. The vault still
  refuses `expired` and the admission owners still check at block time, so
  retaining already-expired bytes is harmless.

## 3. Byte identity (verified)

`encode_typed/1` builds the same ten-field map the signer used to build and
passes it to the unchanged `encode/1`. The vault signs `encode(Request)` of
that same map (`quod_agent_vault:sign/2`, asserted equal at
`quod_agent_vault_tests.erl:24`), and the new assertion at `:305-309` binds
the pure primitive's bytes to the bytes the governed signature verified over.
The only decision point in the codec is `validate_request/1`, which is total
and deterministic over the map. Repeated construction yields equal bytes
(`quod_common_primitives_tests.erl:26`).

## 4. Malformed terms and atom safety (verified)

- Groundness first: a variable anywhere in the intent is an instantiation
  error, not a domain error (`:33-35` of the primitives test).
- Every encoding field is validated by `validate_request/1`: 32-byte
  network, key, operation and anchor; non-empty bounded UTF-8 namespace,
  instance text and goal text; mode in the four-element set; supported
  parser version; expiry a positive integer below 2^64. The typed actor and
  the instance text must encode to one canonical blob
  (`quod_client_goal.erl:82-86`), so the retained bytes cannot name one
  actor in the reference and another in the text.
- Atom safety: the instance text is parsed through `quod_agent_ref:from_text/4`,
  which uses the existing `quod_safe_term` path with
  `binary_to_existing_atom` and no allocation. Mode and parser values come
  from the authored term and are matched against fixed clauses, not
  converted. The goal text is never parsed by the codec.
- Error class: malformed intent is `domain_error(agent_request, Intent)`,
  the same class the signer already raised, so a transaction containing it
  errors rather than failing silently. This matters because quod sets the
  erlog `unknown` flag to `fail` (`quod_committed_projection.erl:59`): a
  missing primitive would fail quietly, a malformed one must not.

## 5. Replacement, not duplication (verified)

The signer's private map construction and its agent-reference equality
check are gone; both now live only in `encode_typed/1`. The second
`sign_typed/4` clause that handled a non-matching shape is subsumed by
`encode_typed(_) -> {error, invalid_request}` mapped to the same domain
error. No old path remains.

## 6. Confirm

`binary/1` appears in a frozen tree for the first time here, but the frozen
`quod_gui.pl` has called it since question-review-01 (`gui_text/1` and the
text-box `gui_value/3` clause), and no other definition exists in erlog, the
live sources or any ontology. With `unknown = fail`, an undefined
`binary/1` would have made every text-box validation fail silently, which
the green question gates since then contradict. The likely explanation is
that the primitive was added live before question-review-01 and simply not
frozen until now. Please confirm that reading, so the record shows one
definition and no window in which the vocabulary ran against a missing
predicate.

## 7. Optional

- A primitives test for instance text that parses with a variable
  (`from_text` requires none) and for a text valid only under a different
  parser version than the one in the intent would pin the two remaining
  branches of the equality check.
- `encode_typed/1` runs `encode/1` before the agent-reference check, so a
  mismatched text with an otherwise invalid request reports
  `invalid_request` from either branch. Acceptable; a note in the doc string
  that the two checks are unordered would save a future reader a question.

## 8. Out of scope

No dispatch, recovery, expiry classification or automatic completion is
enabled by this delta, and nothing here changes the recovery-contract-02
disposition. The GUI question test retracts its inert fact after reading
it; it leaves no new domain state.
