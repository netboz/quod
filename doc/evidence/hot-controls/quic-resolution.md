# QUIC credit and listener lifecycle corrections

The original pin crashes with `{case_clause,-64}` when an accepted send has
reserved stream offsets beyond the peer's current window and another send
arrives before credit advances. The direct-QUIC reproduction uses a real peer,
a 64-byte window and a 128-byte accepted payload; no Quod code is involved.
The correction clamps admission allowance to zero and reports exhausted
connection credit as blocked. A production-token comparison confirms those
are the only semantic changes despite formatter output. The regression suspends
the real peer, observes refusal, resumes it, awaits the existing readiness event
and checks exact delivery including only the explicitly retried refused byte.

The following Quod release run exposed a separate listener lifecycle defect:
`stop_server` acknowledged shutdown before the registry processed `DOWN`, so
an immediate restart could report `already_started`. Registration replacement
also retained the old monitor: its delayed death could delete the replacement.
The existing registry now synchronously releases a stopped registration before
the stop acknowledgement, retains any live replacement, clears superseded
monitors and checks that a death notice still names the current owner.
Two deterministic tests hold the real registry during stop and deliver an old
monitor notice after replacement. Both fail on the old implementation and pass
on the correction; no production polling, retry timer or alternative owner was
introduced. The manual `unregister/1` API remains a live Quod test seam.

[Credit checks](quic-PASSED.json) passed 2,206 EUnit tests and eight readiness
Common Test cases. [Final transport checks](quic-lifecycle-PASSED.json) passed
the formatter, compile, 2,206 EUnit tests, lint, Dialyzer, xref and all ten
readiness/lifecycle Common Test cases. The first transport campaign's socket
round-trip timeout and DNS cancellation remain recorded. The unchanged socket
module passes independently with both revisions; the timeout was not reproduced
or suppressed. A private file-only resolver makes localhost and the invalid-name
fixture deterministic without changing assertions or deadlines.

[Full transport evidence](quic-validation-logs.tar.gz) preserves failures,
baseline/fixed reproductions, source freezes and true exits. Credit commit
`fac1f28520d53ebb2aa59fc42d61f2b45384fd94` is followed by lifecycle commit
`9832288e2fca0c848bc6453cfb4ee7cbfd59ddd5`. Quod's configuration and lockfile
pin the latter. Both were published only to Yan's `netboz/erlang_quic` fork;
no original upstream PR, issue, message or push was made.
