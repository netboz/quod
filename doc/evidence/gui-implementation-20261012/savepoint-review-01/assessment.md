# Independent savepoint review disposition

The parent checked Fable's candidate review against the existing selection,
materialization and local overlay paths. The review ran after the 03:30 Paris
quota reset. It was source-only and is not test evidence.

Accepted the correction to the candidate's premise. An empty materialization
map does not mean foreign state never changed: a cut can remove all live
holders before foreign work. What matters is that every still-live holder is
selected before foreign execution. Its first foreign checkpoint therefore
captures the proper baseline; a discarded holder imposes no historical
baseline. Same actor and lineage preserve local-owner and transaction-owner
identity. Each local choice point still captures its own facts, events,
prepared effects, provenance and transient state.

The implementation uses one pointer in the existing proof context, checks
authorization before reuse, and reuses only an existing empty batch for the
exact actor and lineage. Activation and finish clear the pointer. A foreign
materialization prevents reuse even after restore. Limits and wire tokens are
unchanged. No second owner, history scan or transaction split is introduced.

The alternative of allocating only at materialization is deferred: it would
change token activation and selection more broadly than this demonstrated gap.
The review's approximate batch-count statement is not used as an exact test
oracle: activation baselines and changes of actor/lineage also allocate batches.

Fail-before evidence is retained separately: `savepoint-before-01.log` has
64 tests, one failure, exit 1, through real cohosted foreign proof execution.
`savepoint-before-02.log` has 11 tests, two failures, exit 1: the new reuse
assertion and signed transaction form validation. These are expected defect
reproductions, not passing validation. Final verification is recorded separately.

The implementation review found no defect. Optional extra assertions are not
required for the existing rollback obligations. The final local gate passed
152 tests with zero failures, exit 0. The remote gate retained three passing
action/effect cases and one fixture syntax failure. After adding the missing
closing parenthesis, the expanded remote signed savepoint case passed, exit 0.
The original failed fixture and full logs remain intact. Exact hashes and
results are in ../foundation-validation/savepoint-receipt-01.json.
