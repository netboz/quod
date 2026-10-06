# Authentication readiness delta review

Read-only Fable review. The child did not execute tests or modify files.

The delta is safe and the timing is right.

- **Owner identity at publish time.** The auth server registers through `gen_server:start_link({local, quod_client_auth}, ...)` ([quod_client_auth.erl:70](/home/yan/src/quod/src/quod_client_auth.erl:70)), so the name is bound before `init/1` runs and the notice carries a pid that `whereis` already resolves. The publish is the last action before `{ok, S}`, so no auth state exists that was announced but not constructed, and a crash between notice and first use surfaces as `client_auth_unavailable`, which the enrollment allowlist records as a definite pre-execution refusal, nothing sent.
- **Subscribe before snapshot.** The manager subscribes to `{client_auth, node}` in `init` before it sends itself `enroll_node`, and `start_enrollment` takes its own `whereis` snapshot. Both supervisor orders are covered: at application boot the manager starts first and is woken by the auth notice; on a manager-only restart the auth process already exists and the init-time snapshot finds it. The removed app cast was the only thing covering the first case before, so its removal is correct, not just tidy.
- **Incarnation binding.** `whereis(quod_client_auth) =:= Owner` makes a notice from a dead incarnation harmless: if auth crashed again before the manager processed it, the stale notice is ignored and the new incarnation republishes. A notice from the current incarnation after a crash-and-restart cycle still wakes exactly one enrollment job through the existing dirty flag. No duplicate or stale authority.
- **No polling introduced.** The wake is an owner notification of an installed-state change, scoped to the owner incarnation, which is the pattern the working agreement asks for; nothing retries on a timer.
- **One nit, not a blocker.** `terminate/2` unsubscribes the other topics but not `{client_auth, node}`. gproc subscriptions die with the process, so this is cosmetic, but it breaks the module's own symmetry; add the matching unsubscribe when next touching the file.

Gate status noted: EUnit, ask, quic, simplex, join, agent failover, read set, feed and growth all green with true exits, stopped at the requested boundary with the stop marker retained. The remaining gates, the labeled focused run and the new frozen clean campaign are what stand between this tree and a commit decision; retained live-fleet migration remains unapproved and unrun.
