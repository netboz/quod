# Unsigned positive outcome observation

Read frozen AGENTS.md. Source-only, no commands/tests/production edits. Compare
tree to before for the five changed files. Replace the common Prolog
committed_operation_outcome/3 with /2, exact unsigned execute-request bytes and
status. No signature required for observation: committed exact digest establishes
that the selected bytes were admitted; containing proof ACL unchanged. No parsing
of the goal and no symbol materialization. Scope namespace/anchor checked; altered
network, key, expiry or goal cannot match the certified request digest. In contrast,
future negative expiry will require separate expected-network validation because
no positive certified digest exists. That negative contract is NOT implemented.

Preserve monotonic positive read dependency even on digest/status mismatch;
missing/unpublished/error still live-bridge veto. Verdict/reaction prohibited.
Replace both real physics callers and helper arity, no compatibility shim.
Existing signed HTTP resolver and stored physics custody unchanged.

Tests: full physics/dtx/outcome/commit-validation gate01 still running when packet
frozen. Its newly added assertion incorrectly expected done rather than {complete,[]};
tree has corrected assertion, gate01-test-source.erl preserves original. No pass
claim. Additional altered selector tests and existing backtracking/negation/cut,
no-I/O and unavailable sealing cases exercise actual owners. Write fable-review.md.
