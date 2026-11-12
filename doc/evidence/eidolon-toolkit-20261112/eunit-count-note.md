# Why the eunit totals read 4360, 4403, 4360

Asked by Yan on 2026-11-12: was any test lost?

- Baseline before this work: 4357 (five runs, last `commit284-server-01`).
- This work renames three tests and adds three: 4357 + 3 = 4360. That is the
  total in `phase1-server-01` and `phase3-server-01`.
- `phase2-server-02` counted 4403, 43 more. `quod_agent_hosting_tests` holds
  exactly 43 tests, and its own log lines appear exactly twice in that run
  (`host-test-fipa-receiver` 22 against 11, `host-test-receiver` 14 against 7).
  The run also took about 130 s longer. So that module ran twice in that one
  run; nothing ran less anywhere.
- Why it ran twice is not established. That run was the one started right
  after `phase2-server-01` was killed mid-eunit (rebar3 left `rebar3.crashdump`
  at 10:42 local).

Correction to `phase2-01-stop.md`: the partial log of the killed run ends with
"2663 tests, 10 failures, 3 cancelled". Those ten failures are the teardown of
the killed VM (`noproc` on `quic_server_sup`), not failures of the code.
