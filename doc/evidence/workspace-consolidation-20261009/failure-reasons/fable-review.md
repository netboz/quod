I'll read the five-file test delta, check each new expectation against the approved production code in the release-08 tree, and hash-verify that everything else matches release-07.

Recheck complete on release-08. The five fixture corrections are correct against the approved production code, and tree identity holds.

## Identity, verified by hash

- The 29 previously owned paths are byte-identical to release-07, including every production, spec and doc file.
- The only differences are the five newly owned test files, which are the five files in review-delta.patch. Their task-baseline copies equal the HEAD originals, so the reported test delta is honest.
- No non-owned file differs from release-07. The commit-owned manifest grew from 29 to 34 entries by exactly those five.

## Fixture corrections against production seams

**quod_agent_vault_tests.** `foreign_scope` is correct for both cases: a different namespace and the same namespace with a different anchor both fall to the `{ok, _}` branch in sign_typed. `write_proof` is correct for both the plain write session and the state-check case, because `read_only_state/1` reads the session-level flag and a state check inside a writable session is still a write proof. The old obligation that a staged grant cannot authorize signing is subsumed by the stronger contract that a write session can never sign. The two `domain_error(agent_request, _)` cases match the disagreeing instance text and the non-typed bytes branches. The `invalid_signing_policy` replacement is a real improvement: the pinned erlog installs neither throw/1 nor catch/3, so under `unknown = fail` the old fixture only ever produced a denial. A policy body calling `binary_codes(42, _)` raises a real type error inside `authorization_result`, which maps any caught exception to `invalid`.

**quod_transaction_predicates_tests.** Ground invalid payloads raise `domain_error(event, Term)` and the unbound payload raises `instantiation_error`, matching the two branches in trigger_event. The prove helper calls erlog_int:prove_goal directly, so the throw reaches the assertion.

**quod_agent_custody_tests.** A bound Result hits the shape guard first and raises `domain_error(agent_custody, _)`; a template with a missing or extra hole passes custody and raises `domain_error(preparation_goal, _)` at the result binding. The `{failed, {reaction_guard, Reason}}` shape is what run_reaction returns for a guard error.

**quod_reaction_metadata_tests.** The three cases moved out of the plain-failure list are the three that production now classifies as errors: non-reference target and bound result as `agent_custody` domain errors, an unbound target component as `instantiation_error`. Every remaining plain-failure case is a metadata or recovery mismatch, which the code still fails plainly. The template cases raise `preparation_goal` as the code specifies.

**quod_names_tests.** A non-binary bound first argument reaches `binary_codes_2`'s final clause and raises `type_error(binary, Invalid)`; findall does not catch it, so the throw reaches the assertion.

None of the corrections weaken an obligation. Each asserts the exact class, domain and context term, and the ordinary denials, mismatches, absent metadata and over-ceiling expiry cases keep their plain-failure assertions.

## Disposition

Approve release-08 for commit and release, subject to true-exit receipts for the full sequential campaign on this exact tree. The production code is unchanged from the approved release-07 and all earlier artifacts still apply: the safety invariant is verified, F4 and F8 remain accepted, the untested signing-path reasons now have coverage for the policy-error and context cases, and the commit must contain the commit-owned hunks only.
