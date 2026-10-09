# Authorized hot controls and chair checkpoints

Task `task_1791120421186_fwnpq2`; review requested by Yan, performed with Claude
Fable, and independently checked. [Review disposition](review-resolution.md)
records the verified fixes and retained live branches.

The [exact source freeze](clean-08-manifest.json) and
[gate results](clean-08-PASSED.json) qualify the current code. The freeze includes
the already deployed 0.7.254 ontology-source baseline and movement/control
prerequisites. The feature-only commit closure independently passed 116
physics/control tests before the unrelated peer harness correction.

All gates ran sequentially with full child logs and true exits:

- `native-tests`: exit 0, 34.31 seconds.
- `native-clippy`: exit 0, 27.55 seconds.
- `client-tests`: exit 0, 2.1 seconds.
- `ui-build`: exit 0, 8.59 seconds.
- `ui-lint`: exit 0, 0.42 seconds.
- `eunit`: exit 0, 602.05 seconds.
- `ct`: exit 0, 677.85 seconds.
- `xref`: exit 0, 21.12 seconds.
- `dialyzer`: exit 0, 142.72 seconds.
- `release`: exit 0, 17.37 seconds.

[Full logs](validation-logs.tar.gz) retain the failures and diagnostic attempts,
including clean-01 TLS `eperm` under the filesystem/network sandbox and clean-02
fresh-VM timeout (1851 passed, zero failed assertions, cancelled test group).
Clean-03 stopped at the same LAN DNS wait in the foreign history fresh-VM test
(1088 passed, zero failed assertions, cancelled test group). A focused unchanged
test passed in 0.488 seconds using a private Erlang resolver file mapping this
machine's hostname to loopback. Clean-04 freezes that local test-only mapping;
unmatched names retain native resolution and production configuration is unchanged.
The failed selector attempt preceding that focused test is retained too.
Clean-04 passed 3,794 EUnit tests, then stopped at Common Test (145 passed,
one failed) when the pinned QUIC connection crashed with negative credit.
The [dependency correction and verification](quic-resolution.md) retain its
causal reproduction and all transport gates, including 2,206 EUnit tests and
ten send-readiness/lifecycle CT cases. The exact new SHA is published only on Yan's
fork and frozen in [dependency provenance](clean-08-quic-source.json).
No original upstream repository was notified or changed.
Clean-05 passed its first six gates, including 3,794 EUnit tests, but its CT
process was interrupted by the session transition; no successful CT exit is
claimed. Separately labeled clean-06 continued from the identical source freeze
and stopped at Common Test (145 passed, one auto-skip) because immediate listener
restart hit a stale registry entry. The lifecycle dependency correction is
qualified by old/fixed deterministic reproductions and a fresh complete clean-08
campaign. Clean-07 passed 3,794 EUnit tests, all 146 Common Test cases and xref,
then stopped at two Dialyzer warnings: an ignored refresh-message return and a
missing opaque-session argument spec. A compiler comparison proves both corrections
leave executable instruction, import/export, fun, string and literal chunks
identical to the passing test tree. A separately owned native-client numeric
test fixture update is also frozen and tested, without adding it to this commit
scope. The corrected tree is qualified by a new
full clean-08 campaign. None of the failed or interrupted campaigns was relabeled
as passing.

Tracing located the VM startup wait in native host lookup to LAN DNS. The
canonical-byte test used distributed names although its fixtures travel over
`standard_io`. Removing those unused names eliminates that dependency; the two
fresh VMs, exact module-path checks, byte/hash equality and deadline remain.
Clean-04 also explicitly includes untracked test sources, including the control
test module, in its source freeze.

Production-seam acceptance covers signed authorization, generation/body fences,
duplicate admission, bounded accumulated speed, retained pose on reconciliation,
fresh repeated rest sampling, checkpoint recovery after owner death, atomic
authored invalidation and OCC rejection, cancelled unknown custody, and a fresh
client command after uncertainty without replay. An overlapping recovery
checkpoint fails visibly. Ordinary unchanged reconciliation neither steps the
native world nor writes/syncs files. Host restart follows the same documented
fresh-generation restoration contract; no physical host-failure injection or
hardware chair gesture is claimed.

[Session delta](session-delta.json) measures this session against its starting
dirty tree: +20 production lines, +203 test
lines and +121 documentation lines. Production growth
implements fresh rest evidence and the two reviewed liveness corrections while
removing the obsolete native wrapper and missing-guard bypass. The larger
movement/control foundation is a required dependency, separately recorded in
the commit and source manifest.
