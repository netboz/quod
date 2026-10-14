# Gate receipts

- client-gate01: stopped exit130 after a fixture barrier failed to report a parser error. Failed source and causal record retained in failed-client01.
- client-gate02: direct client test, exit0.
- client-gate03: direct client test including uncertain selection and unavailable journal, exit0.
- server-gate01: GUI questions, examples and physics, 196 tests, 0 failures, true exit0, 202.689 seconds.
- server-gate02: GUI questions with additional tab/expiry lifetime assertions, 2 tests, 0 failures, true exit0, 12.093 seconds.

Production delta against before: +121/-14, net 107, including declarations. No active gate remains. Exact final tree is manifest.json; earlier failed evidence is unchanged.
