# Release 261 test failure diagnosis

Release gate 03 stopped at EUnit with 3,879 tests and two failures. The original
[gate record](../release-261-gates-03/README.md), complete logs and exact source
archive remain intact. The strict unchanged-source disk-I/O assertion is not
filtered or weakened.

The disk calls came from `quod_signing_journal:persist_mutation/2` in a Simplex
process registered for `e2e:6322`, unrelated to the world being checked. The
EUnit test body starts and unlinks its namespace supervisor; fixture cleanup
runs in another process. Its old helper sent `exit(Pid, shutdown)` and silently
returned after five seconds. A supervisor ignores that non-parent exit while
its children continue running, even after cleanup removes their data directory.

- [Diagnostic 01](diagnostics-01/foreign-stop.json) starts a real namespace under
  another live parent. The original helper returns after 5,001 ms with its
  supervisor alive and registered. An explicit OTP stop then cleans it up.
- [Diagnostic 02](diagnostics-02/before-fix.log) is the failing regression against
  the original helper. Its failure is expected and retained.
- [Diagnostic 03](diagnostics-03/result.json) passes eight E2E tests with the
  initial correction. Its empty-inventory line is not relied on: the query
  expression was not retained. Later evidence checks each process explicitly.
- [Diagnostic 04](diagnostics-04/result.json) exits 1 because its raw gproc ETS
  comprehension used the wrong tuple shape. Its empty inventory is invalid.
- [Diagnostic 05](diagnostics-05/expression.erl) uses the documented `gproc:select`
  representation and confirms two surviving namespaces after the unmodified
  create-root module passes all eight tests. It explicitly stops those owners.
- [Diagnostic 06](diagnostics-06/result.json) passes all 170 tests across the
  corrected create-root, E2E and physics modules. The new common helper monitors
  the supervisor and every direct child, stops through OTP, and awaits their
  deaths under the existing five-second bound. The final correct registry query
  finds no live namespaces. The non-parent regression completes in 6 ms.

The other shutdown helpers were inspected for caller ownership and failure
handling. In particular, hosted-agent startup and teardown occur in the same
test process, and teardown raises on timeout. No additional leak was demonstrated
there. Only the two confirmed faulty fixtures use the replacement shared helper.

Fable's [plan review](../release-261-test-plan-review-01/fable-review.md) accepted
the cleanup diagnosis. Its prediction of an "unexpected message" log is not
supported by the installed OTP 28 source: `supervisor:handle_info/2` routes EXIT
messages through `restart_child/3`, whose unknown-PID branch silently returns
the existing state. The actual failed gate has no such log. The traced owner
identity and deterministic reproduction establish the fault directly.

The cancellation failure remains **unexplained**. Twenty focused repetitions and
the full physics module passed before the cleanup correction. Diagnostic 06 also
passes with stricter evidence: it retains alternative DOWN reasons while still
requiring `killed`, checks the parked proof dies, and records worker/proof/socket
state plus the mailbox on timeout. No assertion or original deadline is relaxed.
A subsequent successful full gate would establish non-reproduction after an
unrelated cleanup correction; it would not establish the original cause.

No production Erlang behavior, Prolog policy or persistence guarantee changes in
this test correction.

The [first implementation review](../release-261-test-implementation-review-01/fable-review.md)
found that `supervisor:which_children/1` could block before the cleanup deadline.
Its requested child monitors also duplicated OTP's shutdown guarantee. The final
helper therefore removes both and uses `gen_server:stop(Pid, shutdown, 5000)`
directly. The two old copies remain removed. The non-parent regression preserves
the startup owner's failure reason and avoids masking a primary failure with its
fallback stop.

[Diagnostic 07](diagnostics-07/result.json) passes the final 16 create-root and
E2E tests and finds no live namespaces through the correct registry query.
The proof-death assertion is backed by the existing production caller monitor in
`quod_prolog:spawn_proof/5` and caller-death handling in `finish_proof_down/3`;
the parked test hook is never released. Gate 04 was explicitly interrupted and
retained; gate 05 uses a new exact freeze and must complete before deployment.
Fable's [final review disposition](../release-261-test-implementation-review-02/disposition.md)
records GO and the independent check of the complete caller-ownership path.
